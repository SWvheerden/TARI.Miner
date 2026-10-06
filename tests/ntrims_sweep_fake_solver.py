#!/usr/bin/env python3
"""Stand-in for tari_c29_solver in the ntrims sweep dry runs.

tools/ntrims_sweep.sh --dry-run and tools/ntrims_sweep.ps1 -DryRun run this
instead of the GPU solver. It prints the solver's summary block with made-up
numbers that depend on --ntrims, so the sweep's parsing, stop rules, selection
and table can be tested without a GPU.

TARI_FAKE_SOLVER_SCENARIO picks the numbers (default "edges"):
  edges     g/s +0.3% per 2 rounds below 50; edges grow until 40 is over the limit
  overflow  g/s as edges; small edges; NODE OVERFLOW at 44 and below
  busy      g/s as edges; small edges; projected busy over 40% at 36 and below
  nogain    g/s flat at every ntrims
  noisy     48 has a high median but one slow run; 46 gains; the rest flat
  old       no ntrims statistics lines (a solver built before them)
  crash     exits 1 after the header
  loaddies  the long-running load process exits at once

The cycle-search mean is set so that mean x g/s is the intended busy fraction
(5%, or the busy scenario's value), while the printed measured fraction is
half of that, as when two processes share one GPU. So the sweep's stop rule
must use the projection, not the measured fraction.

TARI_FAKE_SOLVER_STATE, if set, is a file this appends one line per measured
run to, so the noisy scenario can tell the runs of one ntrims apart.
"""

import os
import sys
import time

BASE_GPS = 13.65
MAXEDGES = 1 << 20
LOAD_COUNT = 100000  # a --count above this is a warm-up or load process


def option(argv, name, default):
    if name in argv:
        return argv[argv.index(name) + 1]
    return default


def main(argv):
    scenario = os.environ.get("TARI_FAKE_SOLVER_SCENARIO", "edges")
    ntrims = int(option(argv, "--ntrims", "50"))
    count = int(option(argv, "--count", "256"))
    pipeline = int(option(argv, "--pipeline", "2"))
    device = option(argv, "--device", "0")

    print("TARI.Miner C29 solver fake on FAKE GPU {} (16 GB, sm_89)".format(device))
    print("nonces      = 0 .. {}  ({} graphs)".format(count - 1, count))
    print("target diff = 1\n")
    if pipeline > 1:
        print("solver pipeline={} contexts".format(pipeline))
    sys.stdout.flush()

    if scenario == "crash":
        print("fatal: fake crash", file=sys.stderr)
        return 1
    if count > LOAD_COUNT:
        # Warm-up or load process: run until the sweep stops it.
        if scenario == "loaddies":
            return 0
        deadline = time.time() + 120
        while time.time() < deadline:
            time.sleep(0.1)
        return 0

    run = 0
    state = os.environ.get("TARI_FAKE_SOLVER_STATE")
    if state:
        try:
            with open(state, encoding="utf-8") as handle:
                run = handle.read().split().count(str(ntrims))
        except FileNotFoundError:
            pass
        with open(state, "a", encoding="utf-8") as handle:
            handle.write("{}\n".format(ntrims))

    steps = (50 - ntrims) // 2
    gps = BASE_GPS * (1 + 0.003 * steps)
    edges_max = int(150000 * 1.3 ** steps)
    busy = 0.05
    overflow = 0
    if scenario == "overflow":
        edges_max = 100000
        if ntrims <= 44:
            overflow = 1
            print("NODE OVERFLOW at 1234", file=sys.stderr)
    elif scenario == "busy":
        edges_max = 100000
        busy = 0.10 + 0.025 * (50 - ntrims)
    elif scenario == "nogain":
        gps = BASE_GPS
    elif scenario == "noisy":
        edges_max = 100000
        gps = BASE_GPS
        if ntrims == 48:
            gps = (14.0, 13.0, 14.0)[min(run, 2)]
        elif ntrims == 46:
            gps = 13.75
    oops = 1 if edges_max > MAXEDGES else 0
    if oops:
        print(
            "OOPS; losing {} edges beyond MAXEDGES={}".format(
                edges_max - MAXEDGES, MAXEDGES
            ),
            file=sys.stderr,
        )

    time.sleep(0.3)
    elapsed = count / gps
    ms_p50 = edges_max / 60000.0
    mean_ms = busy / gps * 1000.0
    print("\n--- summary ---")
    print(
        "graphs solved  : {} in {:.2f} s  =>  {:.3f} graphs/s".format(
            count, elapsed, gps
        )
    )
    print("42-cycles found: 0  (expected ~{:.1f} at 1/42 per graph)".format(count / 42.0))
    print("verify failures: 0  (MUST be 0)")
    print("shares (>=1)  : 0")
    if scenario == "old":
        return 0
    print(
        "surviving edges: min={} p50={} p99={} max={}  "
        "(per graph, before the MAXEDGES={} cap)".format(
            edges_max // 4, edges_max // 2, edges_max * 9 // 10, edges_max, MAXEDGES
        )
    )
    print(
        "cycle search ms: p50={:.3f} p99={:.3f} max={:.3f} mean={:.4f}  "
        "(host graph build + cycle finding per graph)".format(
            ms_p50, ms_p50 * 1.5, ms_p50 * 3, mean_ms
        )
    )
    print(
        "cpu busy       : fraction={:.4f}  (cycle search {:.3f} s / wall {:.3f} s)".format(
            busy / 2, busy / 2 * elapsed, elapsed
        )
    )
    print("gpu recovery   : graphs={} total={:.3f} s".format(count // 42, count / 420.0))
    print("lost edges     : oops_graphs={} node_overflow_graphs={}".format(oops, overflow))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
