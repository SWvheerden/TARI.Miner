# Third-Party Notices

## Tromp/cuckoo

`mean_c29.cu`, `graph.hpp`, and `compress.hpp` are derived from the Cuckoo Cycle
reference miner by John Tromp and Jiri Vadura. The minimal build dependencies in
`third_party/cuckoo` were copied from `tromp/cuckoo` commit
`eb76b451673c0b62f8b6b5bbfc71269d129b01e3`.

Upstream copyright:

```text
Copyright (c) 2013-2020 John Tromp
Copyright (c) 2018-2020 Jiri Vadura (photon) and John Tromp
```

Upstream offers the software under the FAIR MINING License or, alternatively,
GNU GPL version 2 or later. This distribution elects the GPL alternative. The
unaltered upstream license is included at `third_party/cuckoo/LICENSE.txt`.

Upstream project: https://github.com/tromp/cuckoo

`third_party/cuckoo/src/crypto/siphash.cuh` is modified (marked
`[tari-c29 portability patch]`) so that the HIP (AMD)
build never uses its NVIDIA PTX inline assembly (64-bit add with carry,
`shf.l.wrap` rotates, `mov.b64`) and takes the plain C++ 64-bit add,
shift/or rotate path instead, which computes the same bits.

## BLAKE2

The BLAKE2 reference files under `third_party/cuckoo/src/crypto` retain their
original copyright and license header. They are offered upstream under CC0,
the OpenSSL License, or Apache License 2.0; this distribution uses the CC0
option.
