// seeda_checkpoint.h - checkpointed SeedA edge schedule (SEEDA_CHECKPOINT).
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Edge i of a 64-edge block is h_i ^ h_63 for i < 63 and h_63 for i = 63,
// where h_i is xor_lanes() after the (i+1)-th hash24 of one rolling state.
// This schedule keeps the first C values in registers, saves the state after
// C hashes, runs on to h_63, then restarts from the saved state for the
// remaining edges: 64 + (63 - C) hashes and C + 4 extra u64 registers.
//
// Shared by SeedA in mean_c29.cu (State = diphash_state<>) and the host test
// tests/tari_seeda_schedule_test.cpp (State = the siphash_state in
// tari_c29.cpp). emit(edge) runs exactly 64 times, in the order 0..63.
// emit() (two barriers, atomics, the flush) and hash24() are large, so every
// loop stays rolled. The buf loops shift buf down by one with an unrolled
// copy, appending at buf[C - 1] or emitting buf[0]: every buf index is a
// constant, so buf stays in registers for about C*C moves per block instead
// of C copies of the hash and emit bodies.

#pragma once

#include <stdint.h>

#ifdef __CUDACC__
#define SEEDA_HD __device__ __forceinline__
#define SEEDA_PRAGMA(x) _Pragma(#x)
#else
#define SEEDA_HD inline
#define SEEDA_PRAGMA(x)
#endif

template <int C, typename State, typename Keys, typename Emit>
SEEDA_HD void seedaCheckpointBlock(const Keys &keys, const uint32_t edge0, Emit &emit) {
  static_assert(C > 0 && C < 64, "checkpoint must fall inside the 64-edge block");
  // Zeroed: the first shifts copy entries not yet written, and reading an
  // indeterminate value is undefined (it also cost registers and spills).
  uint64_t buf[C] = {};
  State shs(keys);
  SEEDA_PRAGMA(unroll 1)
  for (int e = 0; e < C; e++) {
    shs.hash24(edge0 + e);
    SEEDA_PRAGMA(unroll)
    for (int i = 0; i < C - 1; i++)
      buf[i] = buf[i + 1];
    buf[C - 1] = shs.xor_lanes();
  }
  const State ckpt = shs;
  SEEDA_PRAGMA(unroll 1)
  for (int e = C; e < 64; e++)
    shs.hash24(edge0 + e);
  const uint64_t last = shs.xor_lanes();
  SEEDA_PRAGMA(unroll 1)
  for (int e = 0; e < C; e++) {
    emit(buf[0] ^ last);
    SEEDA_PRAGMA(unroll)
    for (int i = 0; i < C - 1; i++)
      buf[i] = buf[i + 1];
  }
  shs = ckpt;
  SEEDA_PRAGMA(unroll 1)
  for (int e = C; e < 64; e++) {
    uint64_t edge;
    if (e < 63) {
      shs.hash24(edge0 + e);
      edge = shs.xor_lanes() ^ last;
    } else {
      edge = last;
    }
    emit(edge);
  }
}
