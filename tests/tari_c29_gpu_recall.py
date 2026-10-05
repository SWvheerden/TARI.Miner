#!/usr/bin/env python3
"""Exact GPU recall regression checks for the Tari C29 solver.

The solver's ``--recall-jsonl`` output is intentionally checked without using
the miner's C++ packing or difficulty code.  A recall file has this shape:

    {"type":"run","mining_hash":"<64 hex>","start_nonce":0,"count":4200,
     "pipeline":1,"ntrims":48,"compiled_ntrims":48,"arch":"sm_120",
     "device_arch":"sm_120","profile":"release"}
    {"type":"cycle","nonce":32,"difficulty":1,"edges":[... 42 integers ...]}
    {"type":"summary","graphs":4200,"cycles":100,"verify_failures":0}

Newer solvers add per-graph cost statistics to the summary record (see
``GRAPH_COST_KEYS``). They are optional, so older recall files still validate;
when present, all of them must be present and consistent. They are timing and
edge-count statistics only and play no part in the proof comparison.

Use ``--help`` for validation, comparison, and live GPU invocation examples.
"""

from __future__ import print_function

import argparse
import contextlib
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import (
    Dict,
    FrozenSet,
    Iterable,
    Iterator,
    List,
    Mapping,
    Optional,
    Sequence,
    Tuple,
)


PROOF_SIZE = 42
EDGE_BITS = 29
EDGE_LIMIT = 1 << EDGE_BITS
PACKED_BYTES = (PROOF_SIZE * EDGE_BITS + 7) // 8
MAX_U64 = (1 << 64) - 1
MAX_U256 = (1 << 256) - 1
DEFAULT_MINING_HASH = "".join("{:02x}".format(i) for i in range(32))
SUPPORTED_ARCHES = ("sm_86", "sm_89", "sm_120")
REFERENCE_NTRIMS = 50
BUILD_FLAGS_DIR = Path(__file__).resolve().parent.parent / "build_flags"
ARCH_FLAGS_ENV = "TARI_ARCH_FLAGS"
NTRIMS_FLAG = re.compile(r"-DTARI_C29_DEFAULT_NTRIMS=(\d+)")

FATAL_PATTERNS = (
    ("fatal", re.compile(r"\bfatal(?:\s*:|\b)", re.IGNORECASE)),
    ("GPU assert", re.compile(r"\bgpu\s*assert(?:ion)?\b", re.IGNORECASE)),
    ("NODE OVERFLOW", re.compile(r"\bnode\s+overflow\b", re.IGNORECASE)),
    ("BUG", re.compile(r"\bbug\b", re.IGNORECASE)),
    (
        "edge truncation",
        re.compile(
            r"\boops;\s*losing\b.*\bedges?\s+beyond\s+maxedges\b",
            re.IGNORECASE,
        ),
    ),
)


# Optional summary keys written by solvers with the ntrims instrumentation.
# Percentiles are nearest-rank; busy_fraction is findcycles_sec / elapsed_sec.
GRAPH_COST_INT_KEYS = (
    "edges_min",
    "edges_p50",
    "edges_p99",
    "edges_max",
    "oops_graphs",
    "node_overflow_graphs",
)
GRAPH_COST_NUMBER_KEYS = (
    "findcycles_ms_p50",
    "findcycles_ms_p99",
    "findcycles_ms_max",
    "findcycles_sec",
    "elapsed_sec",
    "busy_fraction",
)
GRAPH_COST_KEYS = GRAPH_COST_INT_KEYS + GRAPH_COST_NUMBER_KEYS


class RecallError(ValueError):
    """A recall artifact failed a hard validation gate."""


@dataclass(frozen=True, order=True)
class ProofIdentity:
    nonce: int
    proof_hash: str


@dataclass
class RecallDataset:
    path: Path
    metadata: Dict[str, object]
    summary: Dict[str, object]
    proofs: FrozenSet[ProofIdentity]


def parse_arch_flags(text: str) -> List[str]:
    """Split a ``build_flags/<arch>.flags`` body the way the build scripts do.

    Text from ``#`` to end of line is a comment; every remaining
    whitespace-separated word (CR included as whitespace) is one flag.
    """
    flags: List[str] = []
    for line in text.splitlines():
        flags.extend(line.split("#", 1)[0].split())
    return flags


def ntrims_from_flags(flags: Iterable[str]) -> int:
    """Return the TARI_C29_DEFAULT_NTRIMS a flag list compiles in (last wins)."""
    ntrims = REFERENCE_NTRIMS
    for flag in flags:
        match = NTRIMS_FLAG.fullmatch(flag)
        if match:
            ntrims = int(match.group(1))
    return ntrims


def release_compiled_ntrims(
    arch: str,
    flags_dir: Optional[Path] = None,
    environ: Optional[Mapping[str, str]] = None,
) -> int:
    """Trim rounds a release build for ``arch`` compiles in by default.

    Mirrors the build scripts: a non-empty ``TARI_ARCH_FLAGS`` replaces
    ``build_flags/<arch>.flags`` (so set it to the same value the binary was
    built with), otherwise the file is read. A missing file, or no
    ``-DTARI_C29_DEFAULT_NTRIMS=`` flag, means the kernel default of 50.
    """
    env = os.environ if environ is None else environ
    override = env.get(ARCH_FLAGS_ENV, "")
    if override:
        # Like the build scripts: the override is split on whitespace only.
        return ntrims_from_flags(override.split())
    path = (BUILD_FLAGS_DIR if flags_dir is None else Path(flags_dir)) / (
        arch + ".flags"
    )
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return REFERENCE_NTRIMS
    return ntrims_from_flags(parse_arch_flags(text))


def _require_int(
    record: Dict[str, object],
    key: str,
    minimum: int = 0,
    maximum: Optional[int] = None,
) -> int:
    value = record.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise RecallError("{} must be an integer".format(key))
    if value < minimum or (maximum is not None and value > maximum):
        suffix = ""
        if maximum is not None:
            suffix = " and <= {}".format(maximum)
        raise RecallError("{} must be >= {}{}".format(key, minimum, suffix))
    return value


def _require_number(record: Dict[str, object], key: str) -> float:
    value = record.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RecallError("{} must be a number".format(key))
    if not math.isfinite(value) or value < 0:
        raise RecallError("{} must be a finite number >= 0".format(key))
    return float(value)


def _validate_graph_costs(summary: Dict[str, object], graphs: int) -> None:
    """Check the optional per-graph cost keys: all or none, and consistent."""
    present = [key for key in GRAPH_COST_KEYS if key in summary]
    if not present:
        return
    missing = [key for key in GRAPH_COST_KEYS if key not in summary]
    if missing:
        raise RecallError(
            "summary has some graph cost keys but is missing {}".format(
                ", ".join(missing)
            )
        )
    ints = {key: _require_int(summary, key, 0, MAX_U64) for key in GRAPH_COST_INT_KEYS}
    numbers = {key: _require_number(summary, key) for key in GRAPH_COST_NUMBER_KEYS}
    if not (
        ints["edges_min"] <= ints["edges_p50"] <= ints["edges_p99"] <= ints["edges_max"]
    ):
        raise RecallError("summary edges must satisfy min <= p50 <= p99 <= max")
    if not (
        numbers["findcycles_ms_p50"]
        <= numbers["findcycles_ms_p99"]
        <= numbers["findcycles_ms_max"]
    ):
        raise RecallError("summary findcycles_ms must satisfy p50 <= p99 <= max")
    if numbers["busy_fraction"] > 1:
        raise RecallError("summary busy_fraction must be <= 1")
    for key in ("oops_graphs", "node_overflow_graphs"):
        if ints[key] > graphs:
            raise RecallError("summary {} exceeds graphs {}".format(key, graphs))


def _require_nonempty_string(record: Dict[str, object], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value.strip():
        raise RecallError("{} must be a non-empty string".format(key))
    return value


def pack_edges_lsb_first(edges: Sequence[int]) -> bytes:
    """Pack 42 edge nonces as a 153-byte, LSB-first 29-bit stream."""
    if len(edges) != PROOF_SIZE:
        raise RecallError(
            "cycle must contain exactly {} edges, got {}".format(
                PROOF_SIZE, len(edges)
            )
        )

    previous = -1
    packed = bytearray(PACKED_BYTES)
    bit_position = 0
    for index, edge in enumerate(edges):
        if isinstance(edge, bool) or not isinstance(edge, int):
            raise RecallError("edge {} must be an integer".format(index))
        if edge < 0 or edge >= EDGE_LIMIT:
            raise RecallError(
                "edge {} is outside [0, 2^29): {}".format(index, edge)
            )
        if edge <= previous:
            raise RecallError(
                "edges must be strictly ascending (index {}: {} after {})".format(
                    index, edge, previous
                )
            )
        previous = edge

        for source_bit in range(EDGE_BITS):
            if (edge >> source_bit) & 1:
                packed[bit_position >> 3] |= 1 << (bit_position & 7)
            bit_position += 1

    return bytes(packed)


def difficulty_from_digest(digest: bytes) -> int:
    if len(digest) != 32:
        raise RecallError("difficulty digest must be exactly 32 bytes")
    scalar = int.from_bytes(digest, byteorder="big", signed=False)
    if scalar == 0:
        return MAX_U64
    return min(MAX_U256 // scalar, MAX_U64)


def proof_identity(nonce: int, edges: Sequence[int]) -> Tuple[ProofIdentity, int]:
    packed = pack_edges_lsb_first(edges)
    digest = hashlib.blake2b(packed, digest_size=32).digest()
    return (
        ProofIdentity(nonce=nonce, proof_hash=digest.hex()),
        difficulty_from_digest(digest),
    )


def _read_json_records(path: Path) -> List[Tuple[int, Dict[str, object]]]:
    records = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RecallError("cannot read {}: {}".format(path, exc))

    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RecallError(
                "{}:{} is not valid JSON: {}".format(path, line_number, exc.msg)
            )
        if not isinstance(record, dict):
            raise RecallError(
                "{}:{} must contain a JSON object".format(path, line_number)
            )
        records.append((line_number, record))

    if not records:
        raise RecallError("{} contains no JSON records".format(path))
    return records


def _validate_metadata(record: Dict[str, object]) -> Dict[str, object]:
    mining_hash = _require_nonempty_string(record, "mining_hash").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", mining_hash):
        raise RecallError("mining_hash must contain exactly 64 hexadecimal digits")

    has_start_nonce = "start_nonce" in record
    has_nonce_alias = "nonce" in record
    if not has_start_nonce and not has_nonce_alias:
        raise RecallError("run metadata must contain start_nonce")
    start_nonce = _require_int(
        record, "start_nonce" if has_start_nonce else "nonce", 0, MAX_U64
    )
    if has_start_nonce and has_nonce_alias:
        nonce_alias = _require_int(record, "nonce", 0, MAX_U64)
        if nonce_alias != start_nonce:
            raise RecallError("run nonce and start_nonce disagree")

    count = _require_int(record, "count", 1, MAX_U64)
    if start_nonce + count - 1 > MAX_U64:
        raise RecallError("run nonce range exceeds uint64")
    pipeline = _require_int(record, "pipeline", 1, 5)
    ntrims = _require_int(record, "ntrims", 1, 0xFFFF)
    if ntrims & 1:
        raise RecallError("ntrims must be even")
    compiled_ntrims = _require_int(record, "compiled_ntrims", 1, 0xFFFF)
    if compiled_ntrims & 1:
        raise RecallError("compiled_ntrims must be even")
    arch = _require_nonempty_string(record, "arch")
    device_arch = _require_nonempty_string(record, "device_arch")
    if arch not in SUPPORTED_ARCHES:
        raise RecallError(
            "arch must be one of {}".format(", ".join(SUPPORTED_ARCHES))
        )
    if device_arch not in SUPPORTED_ARCHES:
        raise RecallError(
            "device_arch must be one of {}".format(", ".join(SUPPORTED_ARCHES))
        )
    profile = _require_nonempty_string(record, "profile")
    if profile not in ("release", "reference"):
        raise RecallError("profile must be release or reference")
    expected_compiled_ntrims = (
        release_compiled_ntrims(arch) if profile == "release" else 50
    )
    if compiled_ntrims != expected_compiled_ntrims:
        raise RecallError(
            "{} {} build reports compiled_ntrims {}; expected {}".format(
                arch, profile, compiled_ntrims, expected_compiled_ntrims
            )
        )

    metadata = dict(record)
    metadata["mining_hash"] = mining_hash
    metadata["start_nonce"] = start_nonce
    metadata["count"] = count
    metadata["pipeline"] = pipeline
    metadata["ntrims"] = ntrims
    metadata["compiled_ntrims"] = compiled_ntrims
    metadata["arch"] = arch
    metadata["device_arch"] = device_arch
    metadata["profile"] = profile
    return metadata


def find_fatal_log_markers(log_path: Path) -> List[str]:
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise RecallError("cannot read log {}: {}".format(log_path, exc))

    matches = []
    for line_number, line in enumerate(lines, 1):
        for label, pattern in FATAL_PATTERNS:
            if pattern.search(line):
                excerpt = line.strip()
                if len(excerpt) > 200:
                    excerpt = excerpt[:197] + "..."
                matches.append(
                    "{}:{} [{}] {}".format(log_path, line_number, label, excerpt)
                )
    return matches


def load_recall(path: Path, log_path: Optional[Path] = None) -> RecallDataset:
    path = Path(path)
    records = _read_json_records(path)

    first_line, first = records[0]
    if first.get("type") != "run":
        raise RecallError(
            "{}:{} first record must have type \"run\"".format(path, first_line)
        )
    metadata = _validate_metadata(first)

    last_line, last = records[-1]
    if last.get("type") != "summary":
        raise RecallError(
            "{}:{} last record must have type \"summary\"".format(path, last_line)
        )

    proofs = set()
    cycle_records = 0
    start_nonce = int(metadata["start_nonce"])
    count = int(metadata["count"])
    end_nonce = start_nonce + count

    for line_number, record in records[1:-1]:
        record_type = record.get("type")
        if record_type != "cycle":
            raise RecallError(
                "{}:{} unexpected record type {!r}; expected cycle".format(
                    path, line_number, record_type
                )
            )
        nonce = _require_int(record, "nonce", 0, MAX_U64)
        if nonce < start_nonce or nonce >= end_nonce:
            raise RecallError(
                "{}:{} nonce {} is outside [{}, {})".format(
                    path, line_number, nonce, start_nonce, end_nonce
                )
            )
        edges = record.get("edges")
        if not isinstance(edges, list):
            raise RecallError(
                "{}:{} edges must be a JSON array".format(path, line_number)
            )
        identity, computed_difficulty = proof_identity(nonce, edges)
        reported_difficulty = _require_int(record, "difficulty", 0, MAX_U64)
        if reported_difficulty != computed_difficulty:
            raise RecallError(
                "{}:{} difficulty mismatch: reported {}, independently computed {}"
                .format(
                    path,
                    line_number,
                    reported_difficulty,
                    computed_difficulty,
                )
            )
        if identity in proofs:
            raise RecallError(
                "{}:{} duplicate proof ({}, {})".format(
                    path, line_number, identity.nonce, identity.proof_hash
                )
            )
        proofs.add(identity)
        cycle_records += 1

    graphs = _require_int(last, "graphs", 0, MAX_U64)
    summary_cycles = _require_int(last, "cycles", 0, MAX_U64)
    verify_failures = _require_int(last, "verify_failures", 0, MAX_U64)
    if graphs != count:
        raise RecallError(
            "summary graphs {} does not equal requested count {}".format(
                graphs, count
            )
        )
    if summary_cycles != cycle_records:
        raise RecallError(
            "summary cycles {} does not equal {} cycle records".format(
                summary_cycles, cycle_records
            )
        )
    if verify_failures != 0:
        raise RecallError(
            "summary reports {} host verification failures".format(verify_failures)
        )
    _validate_graph_costs(last, graphs)

    if log_path is not None:
        fatal_markers = find_fatal_log_markers(Path(log_path))
        if fatal_markers:
            raise RecallError(
                "fatal marker(s) found in solver log:\n{}".format(
                    "\n".join(fatal_markers)
                )
            )

    return RecallDataset(
        path=path,
        metadata=metadata,
        summary=dict(last),
        proofs=frozenset(proofs),
    )


def compare_recall(
    left: RecallDataset, right: RecallDataset, label: str = "recall"
) -> Dict[str, object]:
    for key in ("mining_hash", "start_nonce", "count", "arch", "device_arch"):
        if left.metadata[key] != right.metadata[key]:
            raise RecallError(
                "{} comparison metadata mismatch for {}: {!r} != {!r}".format(
                    label,
                    key,
                    left.metadata[key],
                    right.metadata[key],
                )
            )

    only_left = sorted(left.proofs - right.proofs)
    only_right = sorted(right.proofs - left.proofs)
    if only_left or only_right:
        def samples(values: Iterable[ProofIdentity]) -> List[Dict[str, object]]:
            return [
                {"nonce": proof.nonce, "proof_hash": proof.proof_hash}
                for proof in list(values)[:5]
            ]

        raise RecallError(
            "{} mismatch: {} proof(s) only on left, {} only on right; "
            "left samples={}, right samples={}".format(
                label,
                len(only_left),
                len(only_right),
                samples(only_left),
                samples(only_right),
            )
        )

    return {
        "name": label,
        "status": "pass",
        "proof_count": len(left.proofs),
        "left": str(left.path),
        "right": str(right.path),
    }


def _dataset_report(dataset: RecallDataset) -> Dict[str, object]:
    return {
        "recall_file": str(dataset.path),
        "metadata": dataset.metadata,
        "summary": dataset.summary,
        "proof_count": len(dataset.proofs),
    }


def _decode_timeout_output(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def _run_solver(
    executable: Path,
    label: str,
    run_dir: Path,
    args: argparse.Namespace,
    pipeline: int,
    ntrims_argument: Optional[int],
    expected_ntrims: int,
    expected_compiled_ntrims: int,
    expected_profile: str,
) -> Tuple[RecallDataset, Dict[str, object]]:
    recall_path = run_dir / (label + ".jsonl")
    log_path = run_dir / (label + ".log")
    command_path = run_dir / (label + ".command.json")
    command = [
        str(executable),
        "--device",
        str(args.device),
        "--count",
        str(args.count),
        "--nonce",
        str(args.nonce),
        "--target",
        str(args.target),
        "--pipeline",
        str(pipeline),
        "--mining-hash",
        args.mining_hash,
        "--recall-jsonl",
        str(recall_path),
    ]
    if ntrims_argument is not None:
        command.extend(("--ntrims", str(ntrims_argument)))

    command_path.write_text(
        json.dumps({"argv": command}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=args.timeout,
            check=False,
        )
        stdout = completed.stdout
        stderr = completed.stderr
        return_code = completed.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = _decode_timeout_output(exc.stdout)
        stderr = _decode_timeout_output(exc.stderr)
        log_path.write_text(
            "[stdout]\n{}\n[stderr]\n{}\n".format(stdout, stderr),
            encoding="utf-8",
        )
        raise RecallError(
            "{} timed out after {} seconds; partial log: {}".format(
                label, args.timeout, log_path
            )
        )
    except OSError as exc:
        raise RecallError("could not start {}: {}".format(executable, exc))

    log_path.write_text(
        "[stdout]\n{}\n[stderr]\n{}\n".format(stdout, stderr),
        encoding="utf-8",
    )
    if return_code != 0:
        raise RecallError(
            "{} exited {}; expected 0 (log: {})".format(
                label, return_code, log_path
            )
        )

    dataset = load_recall(recall_path, log_path)
    expected = {
        "mining_hash": args.mining_hash.lower(),
        "start_nonce": args.nonce,
        "count": args.count,
        "pipeline": pipeline,
        "ntrims": expected_ntrims,
        "compiled_ntrims": expected_compiled_ntrims,
        "arch": args.arch,
        "device_arch": args.arch,
        "profile": expected_profile,
    }
    for key, value in expected.items():
        if dataset.metadata[key] != value:
            raise RecallError(
                "{} metadata {}={!r}; expected {!r}".format(
                    label, key, dataset.metadata[key], value
                )
            )
    if len(dataset.proofs) < args.min_cycles:
        raise RecallError(
            "{} found {} proof(s), fewer than --min-cycles {}".format(
                label, len(dataset.proofs), args.min_cycles
            )
        )

    report = _dataset_report(dataset)
    report.update(
        {
            "label": label,
            "command_file": str(command_path),
            "log_file": str(log_path),
            "exit_code": return_code,
        }
    )
    return dataset, report


def _new_run_directory(parent: Path) -> Path:
    parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
        "recall-%Y%m%dT%H%M%SZ"
    )
    for suffix in range(1000):
        name = stamp if suffix == 0 else "{}-{}".format(stamp, suffix)
        candidate = parent / name
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            continue
    raise RecallError("could not allocate a unique artifact directory in {}".format(parent))


def run_live(args: argparse.Namespace) -> int:
    candidate = Path(args.candidate).resolve()
    reference = Path(args.reference).resolve()
    if not candidate.is_file():
        raise RecallError("candidate executable does not exist: {}".format(candidate))
    if not reference.is_file():
        raise RecallError("reference executable does not exist: {}".format(reference))

    run_dir = _new_run_directory(Path(args.output_dir).resolve())
    report_path = run_dir / "report.json"
    candidate_compiled_ntrims = release_compiled_ntrims(args.arch)
    candidate_actual_ntrims = (
        args.candidate_ntrims
        if args.candidate_ntrims is not None
        else candidate_compiled_ntrims
    )
    reference_compiled_ntrims = 50
    reference_actual_ntrims = args.reference_ntrims

    report = {
        "status": "running",
        "artifact_directory": str(run_dir),
        "parameters": {
            "candidate": str(candidate),
            "reference": str(reference),
            "arch": args.arch,
            "device": args.device,
            "count": args.count,
            "nonce": args.nonce,
            "target": args.target,
            "mining_hash": args.mining_hash.lower(),
            "parity_pipeline": args.parity_pipeline,
            "candidate_ntrims": args.candidate_ntrims,
            "candidate_actual_ntrims": candidate_actual_ntrims,
            "candidate_compiled_ntrims": candidate_compiled_ntrims,
            "reference_ntrims": args.reference_ntrims,
            "reference_compiled_ntrims": reference_compiled_ntrims,
            "min_cycles": args.min_cycles,
        },
        "runs": {},
        "comparisons": [],
        "errors": [],
    }
    datasets = {}

    cases = (
        (
            "candidate-p1-a",
            candidate,
            1,
            args.candidate_ntrims,
            candidate_actual_ntrims,
            candidate_compiled_ntrims,
            "release",
        ),
        (
            "candidate-p1-b",
            candidate,
            1,
            args.candidate_ntrims,
            candidate_actual_ntrims,
            candidate_compiled_ntrims,
            "release",
        ),
        (
            "reference-p1-a",
            reference,
            1,
            args.reference_ntrims,
            reference_actual_ntrims,
            reference_compiled_ntrims,
            "reference",
        ),
        (
            "reference-p1-b",
            reference,
            1,
            args.reference_ntrims,
            reference_actual_ntrims,
            reference_compiled_ntrims,
            "reference",
        ),
        (
            "candidate-parity-p{}".format(args.parity_pipeline),
            candidate,
            args.parity_pipeline,
            args.candidate_ntrims,
            candidate_actual_ntrims,
            candidate_compiled_ntrims,
            "release",
        ),
    )

    try:
        for (
            label,
            executable,
            pipeline,
            ntrims_argument,
            expected_ntrims,
            expected_compiled_ntrims,
            expected_profile,
        ) in cases:
            print("running {} ...".format(label), flush=True)
            dataset, run_report = _run_solver(
                executable,
                label,
                run_dir,
                args,
                pipeline,
                ntrims_argument,
                expected_ntrims,
                expected_compiled_ntrims,
                expected_profile,
            )
            datasets[label] = dataset
            report["runs"][label] = run_report

        comparisons = (
            ("candidate repeatability", "candidate-p1-a", "candidate-p1-b"),
            ("reference repeatability", "reference-p1-a", "reference-p1-b"),
            ("candidate vs reference", "candidate-p1-a", "reference-p1-a"),
            (
                "candidate pipeline parity",
                "candidate-p1-a",
                "candidate-parity-p{}".format(args.parity_pipeline),
            ),
        )
        for label, left_name, right_name in comparisons:
            report["comparisons"].append(
                compare_recall(datasets[left_name], datasets[right_name], label)
            )
        report["status"] = "pass"
    except (RecallError, OSError) as exc:
        report["status"] = "fail"
        report["errors"].append(str(exc))
    finally:
        report_path.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    print("artifacts: {}".format(run_dir))
    print("report: {}".format(report_path))
    if report["status"] != "pass":
        print("FAIL: {}".format(report["errors"][-1]), file=sys.stderr)
        return 1
    print(
        "PASS: exact recall matched across repeats, reference, and pipeline {}".format(
            args.parity_pipeline
        )
    )
    return 0


def _write_fixture(
    path: Path,
    edges: Sequence[int],
    *,
    difficulty: Optional[int] = None,
    graphs: int = 1,
    summary_cycles: int = 1,
    verify_failures: int = 0,
    duplicate: bool = False,
    ntrims: int = 48,
    compiled_ntrims: int = 48,
    arch: str = "sm_120",
    device_arch: str = "sm_120",
    profile: str = "release",
    summary_extra: Optional[Dict[str, object]] = None,
) -> None:
    if difficulty is None:
        try:
            _, computed_difficulty = proof_identity(7, edges)
        except RecallError:
            # Malformed-edge fixtures must reach load_recall(), where their
            # intended validation error is asserted.
            computed_difficulty = 0
    else:
        computed_difficulty = difficulty
    cycle = {
        "type": "cycle",
        "nonce": 7,
        "difficulty": computed_difficulty,
        "edges": list(edges),
    }
    records = [
        {
            "type": "run",
            "mining_hash": DEFAULT_MINING_HASH,
            "start_nonce": 7,
            "count": 1,
            "pipeline": 1,
            "ntrims": ntrims,
            "compiled_ntrims": compiled_ntrims,
            "arch": arch,
            "device_arch": device_arch,
            "profile": profile,
        },
        cycle,
    ]
    if duplicate:
        records.append(dict(cycle))
    records.append(
        {
            "type": "summary",
            "graphs": graphs,
            "cycles": summary_cycles,
            "verify_failures": verify_failures,
        }
    )
    if summary_extra:
        records[-1].update(summary_extra)
    path.write_text(
        "".join(json.dumps(record, sort_keys=True) + "\n" for record in records),
        encoding="utf-8",
    )


@contextlib.contextmanager
def _env_unset(name: str) -> Iterator[None]:
    saved = os.environ.pop(name, None)
    try:
        yield
    finally:
        if saved is not None:
            os.environ[name] = saved


def self_test() -> int:
    expected_packed_hex = (
        "0000002000000008000080010000400000000a00008001000038000000080000"
        "2001000028000080050000c00000001a00008003000078000000100000200200"
        "0048000080090000400100002a000080050000b8000000180000200300006800"
        "00800d0000c00100003a000080070000f8000000200000200400008800008011"
        "0000400200004a000080090000380100002800002005000000"
    )
    expected_hash = (
        "f46d81ccbc7e929376a4f69af8271ad91ea36f9d98cef408a98007de60372481"
    )
    tests_run = 0

    def check(condition: bool, message: str) -> None:
        nonlocal tests_run
        tests_run += 1
        if not condition:
            raise AssertionError(message)

    def expect_recall_error(function, contains: str) -> None:
        nonlocal tests_run
        tests_run += 1
        try:
            function()
        except RecallError as exc:
            if contains.lower() not in str(exc).lower():
                raise AssertionError(
                    "expected error containing {!r}, got {!r}".format(
                        contains, str(exc)
                    )
                )
        else:
            raise AssertionError(
                "expected RecallError containing {!r}".format(contains)
            )

    edges = list(range(PROOF_SIZE))
    packed = pack_edges_lsb_first(edges)
    check(len(packed) == PACKED_BYTES, "packed proof length")
    check(packed.hex() == expected_packed_hex, "LSB-first packing vector")
    identity, difficulty = proof_identity(7, edges)
    check(identity.proof_hash == expected_hash, "BLAKE2b-256 vector")
    check(difficulty == 1, "difficulty vector")
    check(
        difficulty_from_digest(bytes(32)) == MAX_U64,
        "zero digest caps to uint64 maximum",
    )
    no_env: Dict[str, str] = {}
    check(
        release_compiled_ntrims("sm_120", environ=no_env) == 48,
        "sm_120 release ntrims from build_flags",
    )
    check(
        release_compiled_ntrims("sm_89", environ=no_env) == 50,
        "sm_89 release ntrims",
    )
    check(
        release_compiled_ntrims("sm_86", environ=no_env) == 50,
        "sm_86 release ntrims",
    )
    check(
        release_compiled_ntrims("sm_75", environ=no_env) == 50,
        "arch without a flags file uses the default",
    )
    check(
        release_compiled_ntrims(
            "sm_120", environ={ARCH_FLAGS_ENV: "-DX=1 -DTARI_C29_DEFAULT_NTRIMS=44"}
        )
        == 44,
        "TARI_ARCH_FLAGS replaces the flags file",
    )
    check(
        release_compiled_ntrims(
            "sm_120",
            environ={ARCH_FLAGS_ENV: "-DTARI_C29_DEFAULT_NTRIMS=44\t#x\r"},
        )
        == 44,
        "TARI_ARCH_FLAGS is split on whitespace only",
    )
    check(
        release_compiled_ntrims("sm_120", environ={ARCH_FLAGS_ENV: " "}) == 50,
        "blank TARI_ARCH_FLAGS means no extra flags",
    )
    check(
        release_compiled_ntrims("sm_120", environ={ARCH_FLAGS_ENV: ""}) == 48,
        "empty TARI_ARCH_FLAGS is ignored",
    )

    with tempfile.TemporaryDirectory(prefix="tari-recall-selftest-flags-") as temp:
        flags_dir = Path(temp)
        (flags_dir / "sm_empty.flags").write_text("", encoding="utf-8")
        (flags_dir / "sm_comments.flags").write_bytes(
            b"# header\r\n"
            b"\r\n"
            b"#-DTARI_C29_DEFAULT_NTRIMS=40\r\n"
            b"  # -DTARI_C29_DEFAULT_NTRIMS=42\r\n"
            b"-DROUND23_TPB=960 # -DTARI_C29_DEFAULT_NTRIMS=46\r\n"
        )
        (flags_dir / "sm_set.flags").write_bytes(
            b"-DA=1\r\n\t-DTARI_C29_DEFAULT_NTRIMS=52 \t\r\n-DB=2"
        )

        def from_dir(arch: str) -> int:
            return release_compiled_ntrims(arch, flags_dir, no_env)

        check(from_dir("sm_empty") == 50, "empty flags file uses the default")
        check(from_dir("sm_missing") == 50, "missing flags file uses the default")
        check(from_dir("sm_comments") == 50, "commented-out ntrims is ignored")
        check(from_dir("sm_set") == 52, "CRLF flags file with blanks is parsed")
        check(
            parse_arch_flags("-DA=1\r\n\t-DB=2 # c\r\n#-DC=3\n\n")
            == ["-DA=1", "-DB=2"],
            "flag file parsing",
        )

    # The fixtures below assume the committed sm_120 flags; a sweep override
    # in the caller's environment must not change them.
    with _env_unset(ARCH_FLAGS_ENV), tempfile.TemporaryDirectory(
        prefix="tari-recall-selftest-"
    ) as temp:
        root = Path(temp)
        valid = root / "valid.jsonl"
        valid_log = root / "valid.log"
        valid_log.write_text("graphs solved: 1\nverify failures: 0\n", encoding="utf-8")
        _write_fixture(valid, edges)
        dataset = load_recall(valid, valid_log)
        check(len(dataset.proofs) == 1, "valid fixture proof count")
        check(dataset.metadata["start_nonce"] == 7, "valid fixture metadata")
        check(dataset.metadata["compiled_ntrims"] == 48, "compiled ntrims metadata")
        check(dataset.metadata["device_arch"] == "sm_120", "device arch metadata")

        clone = root / "clone.jsonl"
        _write_fixture(clone, edges)
        clone_dataset = load_recall(clone)
        comparison = compare_recall(dataset, clone_dataset, "repeatability")
        check(comparison["proof_count"] == 1, "exact repeat comparison")

        changed = root / "changed.jsonl"
        _write_fixture(changed, list(range(1, PROOF_SIZE + 1)))
        changed_dataset = load_recall(changed)
        expect_recall_error(
            lambda: compare_recall(dataset, changed_dataset, "candidate/reference"),
            "mismatch",
        )

        other_device = root / "other-device.jsonl"
        _write_fixture(other_device, edges, device_arch="sm_89")
        other_device_dataset = load_recall(other_device)
        expect_recall_error(
            lambda: compare_recall(
                dataset, other_device_dataset, "device architecture"
            ),
            "device_arch",
        )

        other_build = root / "other-build.jsonl"
        _write_fixture(
            other_build,
            edges,
            ntrims=50,
            compiled_ntrims=50,
            arch="sm_89",
        )
        other_build_dataset = load_recall(other_build)
        expect_recall_error(
            lambda: compare_recall(dataset, other_build_dataset, "build architecture"),
            "arch",
        )

        bad_compiled_ntrims = root / "bad-compiled-ntrims.jsonl"
        _write_fixture(bad_compiled_ntrims, edges, compiled_ntrims=49)
        expect_recall_error(
            lambda: load_recall(bad_compiled_ntrims),
            "compiled_ntrims must be even",
        )

        wrong_release_default = root / "wrong-release-default.jsonl"
        _write_fixture(wrong_release_default, edges, compiled_ntrims=50)
        expect_recall_error(
            lambda: load_recall(wrong_release_default),
            "expected 48",
        )

        reference = root / "reference.jsonl"
        _write_fixture(
            reference,
            edges,
            ntrims=50,
            compiled_ntrims=50,
            profile="reference",
        )
        reference_dataset = load_recall(reference)
        check(
            reference_dataset.metadata["compiled_ntrims"] == 50,
            "reference compiled ntrims",
        )

        bad_count = root / "bad-count.jsonl"
        _write_fixture(bad_count, edges[:-1])
        expect_recall_error(
            lambda: load_recall(bad_count), "exactly 42 edges"
        )

        bad_order = root / "bad-order.jsonl"
        unordered = list(edges)
        unordered[20] = unordered[19]
        _write_fixture(bad_order, unordered)
        expect_recall_error(lambda: load_recall(bad_order), "strictly ascending")

        bad_range = root / "bad-range.jsonl"
        out_of_range = list(edges)
        out_of_range[-1] = EDGE_LIMIT
        _write_fixture(bad_range, out_of_range)
        expect_recall_error(lambda: load_recall(bad_range), "outside")

        bad_difficulty = root / "bad-difficulty.jsonl"
        _write_fixture(bad_difficulty, edges, difficulty=2)
        expect_recall_error(
            lambda: load_recall(bad_difficulty), "difficulty mismatch"
        )

        bad_graphs = root / "bad-graphs.jsonl"
        _write_fixture(bad_graphs, edges, graphs=0)
        expect_recall_error(lambda: load_recall(bad_graphs), "requested count")

        bad_summary = root / "bad-summary.jsonl"
        _write_fixture(bad_summary, edges, summary_cycles=0)
        expect_recall_error(lambda: load_recall(bad_summary), "cycle records")

        bad_verify = root / "bad-verify.jsonl"
        _write_fixture(bad_verify, edges, verify_failures=1)
        expect_recall_error(
            lambda: load_recall(bad_verify), "verification failures"
        )

        duplicate = root / "duplicate.jsonl"
        _write_fixture(duplicate, edges, summary_cycles=2, duplicate=True)
        expect_recall_error(lambda: load_recall(duplicate), "duplicate proof")

        # Per-graph cost keys are optional: the old-format "valid" fixture
        # above has none of them.
        graph_costs = {
            "edges_min": 90000,
            "edges_p50": 120000,
            "edges_p99": 150000,
            "edges_max": 160000,
            "findcycles_ms_p50": 4.5,
            "findcycles_ms_p99": 7.25,
            "findcycles_ms_max": 9.0,
            "findcycles_sec": 0.005,
            "elapsed_sec": 0.2,
            "busy_fraction": 0.025,
            "oops_graphs": 0,
            "node_overflow_graphs": 0,
        }
        with_costs = root / "with-costs.jsonl"
        _write_fixture(with_costs, edges, summary_extra=graph_costs)
        with_costs_dataset = load_recall(with_costs)
        check(
            with_costs_dataset.summary["edges_max"] == 160000,
            "summary with graph cost keys validates",
        )
        check(
            compare_recall(dataset, with_costs_dataset, "old vs new")["proof_count"]
            == 1,
            "graph cost keys do not affect the proof comparison",
        )
        integer_ms = dict(graph_costs, findcycles_ms_max=9, busy_fraction=0)
        integer_ms_path = root / "integer-ms.jsonl"
        _write_fixture(integer_ms_path, edges, summary_extra=integer_ms)
        check(
            load_recall(integer_ms_path).summary["findcycles_ms_max"] == 9,
            "integral JSON numbers are accepted for timing keys",
        )

        bad_costs = (
            ("partial", {"edges_max": 5}, "missing"),
            ("string", {"edges_p99": "150000"}, "edges_p99 must be an integer"),
            ("float edges", {"edges_min": 1.5}, "edges_min must be an integer"),
            ("bool", {"oops_graphs": False}, "oops_graphs must be an integer"),
            ("negative", {"edges_min": -1}, "edges_min must be >= 0"),
            ("negative ms", {"findcycles_ms_p50": -0.5}, "finite number"),
            # json.loads accepts NaN, which is not valid JSON.
            ("nan", {"elapsed_sec": float("nan")}, "finite number"),
            ("string ms", {"findcycles_sec": "1"}, "must be a number"),
            ("edge order", {"edges_p50": 170000}, "min <= p50"),
            ("ms order", {"findcycles_ms_p99": 10.0}, "p50 <= p99"),
            ("busy", {"busy_fraction": 1.5}, "busy_fraction"),
            ("oops count", {"oops_graphs": 2}, "exceeds graphs"),
        )
        for name, change, message in bad_costs:
            extra = change if name == "partial" else dict(graph_costs, **change)
            bad_path = root / "bad-costs-{}.jsonl".format(name.replace(" ", "-"))
            _write_fixture(bad_path, edges, summary_extra=extra)
            expect_recall_error(lambda path=bad_path: load_recall(path), message)

        fatal_log = root / "fatal.log"
        fatal_log.write_text(
            "GPUASSERT while recovering\n"
            "NODE OVERFLOW\n"
            "BUG\n"
            "fatal: CUDA error\n"
            "OOPS; losing 12 edges beyond MAXEDGES\n",
            encoding="utf-8",
        )
        markers = find_fatal_log_markers(fatal_log)
        check(len(markers) == 5, "all fatal log marker classes")
        check(
            any("[edge truncation]" in marker for marker in markers),
            "MAXEDGES truncation is fatal",
        )
        expect_recall_error(
            lambda: load_recall(valid, fatal_log), "fatal marker"
        )

    print("PASS: {} Tari C29 GPU recall self-test checks".format(tests_run))
    return 0


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def _pipeline(value: str) -> int:
    parsed = int(value)
    if parsed < 1 or parsed > 5:
        raise argparse.ArgumentTypeError("must be in [1, 5]")
    return parsed


def _even_ntrims(value: str) -> int:
    parsed = int(value)
    if parsed < 2 or parsed > 0xFFFF or parsed & 1:
        raise argparse.ArgumentTypeError("must be a positive even integer <= 65535")
    return parsed


def _hex32(value: str) -> str:
    normalized = value.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise argparse.ArgumentTypeError("must contain exactly 64 hexadecimal digits")
    return normalized


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Validate and compare exact Tari C29 GPU cycle recall. The live "
            "runner performs candidate and reference repeatability checks, an "
            "exact candidate/reference comparison, and candidate pipeline parity."
        ),
        epilog=(
            "examples:\n"
            "  python tests/tari_c29_gpu_recall.py --self-test\n"
            "  python tests/tari_c29_gpu_recall.py validate run.jsonl --log run.log\n"
            "  python tests/tari_c29_gpu_recall.py compare a.jsonl b.jsonl\n"
            "  python tests/tari_c29_gpu_recall.py run --candidate bin/solver.exe "
            "--reference bin/validation/solver_reference.exe "
            "--output-dir validation --arch sm_120 --parity-pipeline 4"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run dependency-free CPU fixtures and exit",
    )
    subparsers = parser.add_subparsers(dest="command")

    validate_parser = subparsers.add_parser(
        "validate", help="validate one existing recall JSONL artifact"
    )
    validate_parser.add_argument("recall", type=Path)
    validate_parser.add_argument(
        "--log", type=Path, help="also reject fatal markers in this solver log"
    )

    compare_parser = subparsers.add_parser(
        "compare", help="validate and exactly compare two recall JSONL artifacts"
    )
    compare_parser.add_argument("left", type=Path)
    compare_parser.add_argument("right", type=Path)
    compare_parser.add_argument("--left-log", type=Path)
    compare_parser.add_argument("--right-log", type=Path)

    run_parser = subparsers.add_parser(
        "run", help="run the complete five-invocation GPU recall sequence"
    )
    run_parser.add_argument("--candidate", required=True, type=Path)
    run_parser.add_argument("--reference", required=True, type=Path)
    run_parser.add_argument("--output-dir", required=True, type=Path)
    run_parser.add_argument(
        "--arch",
        required=True,
        choices=SUPPORTED_ARCHES,
        help="required embedded build target and runtime device capability",
    )
    run_parser.add_argument("--parity-pipeline", required=True, type=_pipeline)
    run_parser.add_argument("--device", type=int, default=0)
    run_parser.add_argument("--count", type=_positive_int, default=4200)
    run_parser.add_argument("--nonce", type=int, default=0)
    run_parser.add_argument("--target", type=_positive_int, default=1)
    run_parser.add_argument(
        "--mining-hash", type=_hex32, default=DEFAULT_MINING_HASH
    )
    run_parser.add_argument(
        "--candidate-ntrims",
        type=_even_ntrims,
        help="override candidate ntrims; otherwise use its compiled default",
    )
    run_parser.add_argument(
        "--reference-ntrims",
        type=_even_ntrims,
        default=50,
        help="reference ntrims (default: 50)",
    )
    run_parser.add_argument(
        "--min-cycles",
        type=_positive_int,
        default=1,
        help="minimum proofs required from every live run (default: 1)",
    )
    run_parser.add_argument(
        "--timeout",
        type=_positive_int,
        default=1800,
        help="per-invocation timeout in seconds (default: 1800)",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        if args.command is not None:
            parser.error("--self-test cannot be combined with a command")
        return self_test()
    if args.command is None:
        parser.print_help()
        return 2

    try:
        if args.command == "validate":
            dataset = load_recall(args.recall, args.log)
            print(json.dumps(_dataset_report(dataset), indent=2, sort_keys=True))
            return 0
        if args.command == "compare":
            left = load_recall(args.left, args.left_log)
            right = load_recall(args.right, args.right_log)
            result = compare_recall(left, right, "exact recall")
            print(json.dumps(result, indent=2, sort_keys=True))
            return 0
        if args.command == "run":
            if args.device < 0:
                raise RecallError("--device must be non-negative")
            if args.nonce < 0 or args.nonce > MAX_U64:
                raise RecallError("--nonce must fit uint64")
            if args.nonce + args.count - 1 > MAX_U64:
                raise RecallError("requested nonce range exceeds uint64")
            if args.parity_pipeline == 1:
                raise RecallError("--parity-pipeline must differ from pipeline 1")
            return run_live(args)
    except (RecallError, OSError) as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        return 1

    parser.error("unsupported command")
    return 2


if __name__ == "__main__":
    sys.exit(main())
