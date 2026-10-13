# AMD GPU validation (HIP build)

A self-contained brief for a first run of the AMD backends on real hardware.
The AMD build (`amd` arch, HIP) compiles in CI and passes every host test, but
has never run on an AMD GPU. These steps check that it finds exactly the same
proofs as the reference build, that the pool miner works end to end, and
measure its speed.

Rules:

- **Local only.** Do not connect to a real mining pool. The pool miner step
  uses a stub pool on 127.0.0.1 (below).
- Do not change `build_flags/amd.flags` or any source file. Report numbers and
  logs; tuning comes later, and only after the recall check passes.
- Linux with an RDNA2, RDNA3 or RDNA4 GPU (gfx1030, gfx1031, gfx1032, gfx1100,
  gfx1101, gfx1102, gfx1200 or gfx1201) and at least 8 GB of VRAM.
- ROCm 7.2 or newer with `hipcc`, Python 3, git, and the repository checked
  out. Run every command from the repository root.

## Step 1: build

Building for only the GPU under test is faster. Take its gfx name from
`rocminfo | grep -m1 -o 'gfx1[0-9a-f]*'` (or from step 2 after a full build):

```bash
export AMD_OFFLOAD_ARCHES=gfx1100        # the card's gfx name
./build_solver.sh amd
./build_solver.sh amd reference
./build_pool_miner.sh amd
ldd bin/tari_c29_pool_miner_amd | grep amdhip64
```

Without `AMD_OFFLOAD_ARCHES` the build covers all eight targets, like the
release. Each build prints `BUILD OK`. Record `hipcc --version` and the ROCm
version (`cat /opt/rocm/.info/version`).

## Step 2: device list

```bash
bin/tari_c29_pool_miner_amd --list-devices
```

Expect one line per AMD GPU, `index<TAB>name<TAB>gfx name<TAB>PCI bus`
(bus in hex), for example `0	AMD Radeon RX 7900 XTX	gfx1100	03`, and exit
code 0. With no usable GPU
it prints nothing on stdout and `no HIP GPU devices found: ...` on stderr.
Use the index in `--device N` below (default 0).

The list can include GPUs the backend does not support, such as the
integrated graphics of a Ryzen CPU (gfx1036, gfx1103, gfx115x) or an RX 6400
or 6500 (gfx1034). `start-c29.sh` skips those with a warning. If the HIP
runtime itself fails or misbehaves because of such a GPU, hide it with
`HIP_VISIBLE_DEVICES`, a comma-separated list of the device indexes the
runtime may use, for example `export HIP_VISIBLE_DEVICES=0`. Indexes are then
renumbered from 0.

## Step 3: smoke test

```bash
bin/tari_c29_solver_amd --device 0 --count 320 --pipeline 1
```

The first line names the GPU and its gfx name. The run must end with
`verify failures: 0` and find a few 42-cycles (about 1 in 42 graphs). A
`fatal:` line, a `GPUassert`, or `this build needs 32-lane wavefronts` is a
failure: stop and report the full output.

## Step 4: exact recall (two gates, both required)

Both gates must pass before the AMD build counts as correct. Gate 4a compares
AMD builds with each other; it cannot catch a bug they share (both use the
same HIP warp helpers and siphash code). Gate 4b compares the AMD proofs with
proofs found on an NVIDIA GPU, which catches that.

### Gate 4a: AMD release against the AMD reference build

This runs the release (candidate) and the conservative reference build twice
each on 4,200 fixed graphs, plus the candidate at pipeline 2, and requires
every run to find the same set of proofs. Every proof is also checked by the
solver's CPU verifier and again by the script's own Python packing and
hashing:

```bash
unset TARI_ARCH_FLAGS
python3 tests/tari_c29_gpu_recall.py run \
  --candidate bin/tari_c29_solver_amd \
  --reference bin/validation/tari_c29_solver_amd_reference \
  --arch amd --device 0 --output-dir validation --parity-pipeline 2
```

Pass: it prints `PASS` and exits 0. It writes `validation/recall-*/` with
`report.json`, the raw logs and the JSONL proof records. A failure is a result
too: keep the directory and report it.

### Gate 4b: AMD proofs against NVIDIA proofs

The maintainer supplies the NVIDIA proofs: the `reference-p1-a.jsonl` file
from the same `tests/tari_c29_gpu_recall.py run` command run on an NVIDIA card
(for example `--arch sm_89`) with the same defaults: default mining hash,
`--nonce 0`, `--count 4200`, and 50 trim rounds (the reference build always
uses 50). Save it as `validation/nvidia-reference.jsonl`. Without that file
this gate has not been run: report it as NOT RUN, not as passed.

Compare both AMD 50-round runs from gate 4a with it. `compare-proofs`
checks that the files cover the same graphs (mining hash, start nonce, count)
with the same trim rounds, that the NVIDIA file holds at least one proof, and
that both hold exactly the same set of proofs (each a nonce and its 42
edges). The GPU architectures may differ. It needs nothing beyond Python 3:

```bash
run_dir="$(ls -d validation/recall-* | tail -n 1)"
for label in candidate-p1-a reference-p1-a; do
  python3 tests/tari_c29_gpu_recall.py compare-proofs \
    --reference validation/nvidia-reference.jsonl \
    --candidate "$run_dir/$label.jsonl"
  echo "gate 4b $label: exit $?"
done
```

Pass: both commands print `PASS: N identical proofs ...` and exit 0. Any
`FAIL:` line (it names the setting that differs, or how many proofs are only
on one side with samples) or a non-zero exit is a FAIL: report the output.

## Step 5: speed

```bash
for run in 1 2 3; do
  bin/tari_c29_solver_amd --device 0 --count 2000 | grep -E 'solver pipeline|graphs solved'
done
```

Report the pipeline depth it chose and the three graphs/s values. Then, once,
the per-stage times at pipeline 1 (a separate build; rebuild the release
binary afterwards):

```bash
TARI_ARCH_FLAGS="-DTRIM_STAGE_TIMING=1" ./build_solver.sh amd
bin/tari_c29_solver_amd --device 0 --count 200 --pipeline 1 | grep '^stage-ms' | tail -n 100 > stage-ms.txt
unset TARI_ARCH_FLAGS; ./build_solver.sh amd
```

## Step 6: pool miner against a local stub pool

Save this stub as `/tmp/stub_pool.py`. It speaks the pool's JSON-RPC dialect
on 127.0.0.1:3333: it answers the login with a job of difficulty 1 (so every
cycle found is a share), sends a new job every 60 seconds, and accepts every
submit.

```python
import json, os, socket, threading, time

def send(conn, obj):
    conn.sendall((json.dumps(obj, separators=(",", ":")) + "\n").encode())

def job(height):
    return {"blob": os.urandom(32).hex(), "job_id": str(height),
            "target": "ffffffffffffffff", "height": height}

def serve(conn):
    height = 1
    submits = 0
    last_job = time.time()
    buf = b""
    conn.settimeout(1.0)
    while True:
        if time.time() - last_job >= 60:
            height += 1
            last_job = time.time()
            send(conn, {"jsonrpc": "2.0", "method": "job", "params": job(height)})
            print("sent job height", height, flush=True)
        try:
            data = conn.recv(65536)
        except socket.timeout:
            continue
        if not data:
            print("miner disconnected; submits:", submits, flush=True)
            return
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("method") == "login":
                send(conn, {"id": msg["id"], "jsonrpc": "2.0", "error": None,
                            "result": {"id": "stub", "job": job(height), "status": "OK"}})
                print("login", msg["params"]["login"], flush=True)
            elif msg.get("method") == "submit":
                submits += 1
                send(conn, {"id": msg["id"], "jsonrpc": "2.0", "error": None,
                            "result": {"status": "OK"}})
                print("submit", submits, "job", msg["params"]["job_id"],
                      "nonce", msg["params"]["nonce"], flush=True)

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 3333))
server.listen(1)
while True:
    conn, _ = server.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
```

Then:

```bash
python3 /tmp/stub_pool.py > stub.log 2>&1 &
bin/tari_c29_pool_miner_amd --pool 127.0.0.1:3333 --wallet amd-test \
  --worker amd0 --device 0 --max-runtime-sec 300 > miner.log 2>&1
echo "miner exit $?"
kill %1
```

Expect exit code 0, `new job height=...` lines, `share accepted` lines, and a
`speed ... accepted=N rejected=0` report every 15 seconds. The number of
submits in `stub.log` must equal the miner's final `submitted`.

Also check the launcher picks the GPU up, without starting anything:

```bash
TARI_DRY_RUN=1 TARI_WALLET=amd-test TARI_POOL=127.0.0.1:3333 ./start-c29.sh
```

It should print `AMD GPU 0 [...] gfx... -> amd, worker <host>-amd0` and a
`[DRY RUN]` command line using `bin/tari_c29_pool_miner_amd`.

## What to report back

1. GPU model, gfx name, VRAM; `--list-devices` output; ROCm version,
   `hipcc --version`, kernel and distribution; CPU model and core count.
2. Step 3: the full solver output.
3. Step 4: gate 4a PASS or FAIL with `report.json`; gate 4b PASS, FAIL or
   NOT RUN with the full `compare-proofs` output;
   and `candidate-p1-a.jsonl` and `reference-p1-a.jsonl`.
4. Step 5: the pipeline depth, the three graphs/s values, and `stage-ms.txt`.
5. Step 6: the miner's exit code, the first 20 lines and the last speed report
   of `miner.log`, and the submit count from `stub.log`.
6. While mining: `rocm-smi --showtemp --showpower --showuse` once.
7. Anything unexpected, with the complete output.
