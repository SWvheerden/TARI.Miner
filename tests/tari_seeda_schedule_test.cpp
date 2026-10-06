// Host check of the SeedA edge schedules (no GPU). For random keys and edge
// blocks, the buffer (dipblock), rehash (SEEDA_REHASH=1) and checkpoint
// (SEEDA_CHECKPOINT=8/16/32) schedules must emit exactly 64 edges each, with
// the same multiset of values, and the buffer schedule must match the
// reference tari_c29_edge() for every edge of the block.
//
// The checkpoint schedule is the seedaCheckpointBlock() template that SeedA
// itself uses. The buffer and rehash schedules are scalar copies of
// dipblock() and the SEEDA_REHASH loop in mean_c29.cu.

#include <algorithm>
#include <cstdio>
#include <random>
#include <vector>

#include "../tari_c29.cpp" // siphash_state and tari_c29_edge()
#include "../seeda_checkpoint.h"

static int failures = 0;

static std::vector<u64> buffer_schedule(const tari_siphash_keys &keys, const u32 edge0) {
    std::vector<u64> out;
    siphash_state shs(keys);
    u64 buf[EDGE_BLOCK_SIZE];
    u32 i;
    for (i = 0; i < EDGE_BLOCK_MASK; i++) {
        shs.hash24(edge0 + i);
        buf[i] = shs.xor_lanes();
    }
    shs.hash24(edge0 + i);
    buf[i] = 0;
    const u64 last = shs.xor_lanes();
    for (u32 e = 0; e < EDGE_BLOCK_SIZE; e++)
        out.push_back(buf[e] ^ last);
    return out;
}

static std::vector<u64> rehash_schedule(const tari_siphash_keys &keys, const u32 edge0) {
    std::vector<u64> out;
    siphash_state lastState(keys);
    for (u32 e = 0; e < EDGE_BLOCK_SIZE; e++)
        lastState.hash24(edge0 + e);
    const u64 last = lastState.xor_lanes();
    siphash_state shs(keys);
    for (u32 e = 0; e < EDGE_BLOCK_SIZE; e++) {
        u64 edge;
        if (e < EDGE_BLOCK_MASK) {
            shs.hash24(edge0 + e);
            edge = shs.xor_lanes() ^ last;
        } else {
            edge = last;
        }
        out.push_back(edge);
    }
    return out;
}

template <int C>
static std::vector<u64> checkpoint_schedule(const tari_siphash_keys &keys, const u32 edge0) {
    std::vector<u64> out;
    auto emit = [&](const u64 edge) { out.push_back(edge); };
    seedaCheckpointBlock<C, siphash_state>(keys, edge0, emit);
    return out;
}

static void expect_same(const char *name, const tari_siphash_keys &keys, const u32 edge0,
                        const std::vector<u64> &expected, std::vector<u64> actual) {
    if (actual.size() != EDGE_BLOCK_SIZE) {
        std::fprintf(stderr, "FAIL %s block %u: %zu emits, expected %u\n",
                     name, edge0, actual.size(), EDGE_BLOCK_SIZE);
        failures++;
        return;
    }
    std::vector<u64> want = expected;
    std::sort(want.begin(), want.end());
    std::sort(actual.begin(), actual.end());
    if (actual != want) {
        std::fprintf(stderr, "FAIL %s block %u keys %016llx: edge multiset differs\n",
                     name, edge0, (unsigned long long)keys.k0);
        failures++;
    }
}

static void check_block(const tari_siphash_keys &keys, const u32 edge0) {
    const std::vector<u64> buffer = buffer_schedule(keys, edge0);
    for (u32 e = 0; e < EDGE_BLOCK_SIZE; e++) {
        u32 u, v;
        tari_c29_edge(&keys, edge0 + e, &u, &v);
        if ((buffer[e] & EDGEMASK) != u || ((buffer[e] >> 32) & EDGEMASK) != v) {
            std::fprintf(stderr, "FAIL buffer edge %u differs from tari_c29_edge\n", edge0 + e);
            failures++;
        }
    }
    expect_same("rehash", keys, edge0, buffer, rehash_schedule(keys, edge0));
    expect_same("checkpoint 8", keys, edge0, buffer, checkpoint_schedule<8>(keys, edge0));
    expect_same("checkpoint 16", keys, edge0, buffer, checkpoint_schedule<16>(keys, edge0));
    expect_same("checkpoint 32", keys, edge0, buffer, checkpoint_schedule<32>(keys, edge0));
}

int main() {
    std::mt19937_64 rng(0x5eedac4ec7ULL);
    int blocks = 0;
    for (int k = 0; k < 8; k++) {
        tari_siphash_keys keys = {rng(), rng(), rng(), rng()};
        check_block(keys, 0);
        check_block(keys, NEDGES - EDGE_BLOCK_SIZE);
        blocks += 2;
        for (int b = 0; b < 16; b++) {
            check_block(keys, (u32)rng() & EDGEMASK & ~EDGE_BLOCK_MASK);
            blocks++;
        }
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("SeedA schedule tests passed (%d blocks)\n", blocks);
    return 0;
}
