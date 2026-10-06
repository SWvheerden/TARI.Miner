// GPU-independent regressions for the cycle-finding graph reset.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Build with -I. -Ithird_party/cuckoo/src/cuckaroo (graph.hpp includes
// bitmap.hpp). Run with -DGRAPH_UNION_SKIP=0 and =1.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <memory>
#include <random>
#include <vector>

typedef uint32_t u32;
typedef uint32_t word_t;
#define EDGEBITS 29
#define PROOFSIZE 42
#define SQUASH_OUTPUT 1

#include "graph.hpp"

static int failures = 0;

static void check(bool condition, const char *name) {
    std::printf("  [%s] %s\n", condition ? "PASS" : "FAIL", name);
    if (!condition) failures++;
}

struct Edge {
    word_t u;
    word_t v;
};

static word_t random_node(std::mt19937 &rng) {
    return (word_t)(rng() & (((word_t)1 << EDGEBITS) - 1));
}

// Adds a cycle of the given (even) length on fresh random nodes.
static void plant_cycle(std::vector<Edge> &edges, u32 len, std::mt19937 &rng) {
    std::vector<word_t> us, vs;
    for (u32 i = 0; i < len / 2; i++) {
        us.push_back(random_node(rng));
        vs.push_back(random_node(rng));
    }
    for (u32 i = 0; i < len / 2; i++) {
        edges.push_back({us[i], vs[i]});
        edges.push_back({us[(i + 1) % (len / 2)], vs[i]});
    }
}

// Random edges plus a planted 42-cycle (if wanted) and some short cycles,
// shuffled so the cycle edges are spread through the list.
static std::vector<Edge> make_edges(u32 nrandom, bool with_solution, std::mt19937 &rng) {
    std::vector<Edge> edges;
    for (u32 i = 0; i < nrandom; i++)
        edges.push_back({random_node(rng), random_node(rng)});
    if (with_solution)
        plant_cycle(edges, PROOFSIZE, rng);
    plant_cycle(edges, 4, rng);
    plant_cycle(edges, 8, rng);
    plant_cycle(edges, 20, rng);
    std::shuffle(edges.begin(), edges.end(), rng);
    return edges;
}

static void add_all(graph<word_t> &g, const std::vector<Edge> &edges) {
    for (const Edge &e : edges) {
        if (g.compressu)
            g.add_compress_edge(e.u, e.v);
        else
            g.add_edge(e.u % g.MAXNODES, e.v % g.MAXNODES);
    }
}

static bool same_result(const graph<word_t> &a, const graph<word_t> &b) {
    if (a.nsols != b.nsols || a.nlinks != b.nlinks)
        return false;
    for (u32 s = 0; s < a.nsols; s++) {
        if (std::memcmp(a.sols[s], b.sols[s], sizeof(proof)) != 0)
            return false;
    }
    return true;
}

static bool all_nil(const word_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (p[i] != graph<word_t>::NIL)
            return false;
    }
    return true;
}

// True when every buffer that reset() is responsible for is back to NIL.
static bool fully_reset(const graph<word_t> &g) {
    if (!all_nil(g.adjlist, 2 * (size_t)g.MAXNODES))
        return false;
#if GRAPH_UNION_SKIP
    if (!all_nil(g.ufparent, 2 * (size_t)g.MAXNODES))
        return false;
#endif
    if (g.compressu) {
        if (!all_nil(g.compressu->nodes, g.compressu->SIZE2) ||
            !all_nil(g.compressv->nodes, g.compressv->SIZE2))
            return false;
        if (g.compressu->nnodes != 0 || g.compressv->nnodes != 0)
            return false;
    }
    return g.nlinks == 0 && g.nsols == 0;
}

// Builds every edge set in a row on one graph that uses reset(), and checks
// each result against a freshly built graph that used reset_full().
template <class MakeGraph>
static void run_rounds(MakeGraph make_graph, const std::vector<std::vector<Edge>> &sets,
                       const char *name, u32 *total_sols) {
    std::unique_ptr<graph<word_t>> g(make_graph());
    bool same = true;
    bool clean = true;
    *total_sols = 0;
    for (const std::vector<Edge> &edges : sets) {
        g->reset();
        clean = clean && fully_reset(*g);
        add_all(*g, edges);

        std::unique_ptr<graph<word_t>> fresh(make_graph());
        fresh->reset_full();
        add_all(*fresh, edges);

        same = same && same_result(*g, *fresh);
        *total_sols += g->nsols;
    }
    char label[160];
    std::snprintf(label, sizeof(label), "%s: buffers are clear after every reset()", name);
    check(clean, label);
    std::snprintf(label, sizeof(label), "%s: nsols and sols match a reset_full() graph", name);
    check(same, label);
}

// The solver's graph: EDGEBITS 29, IDXSHIFT 9, MAXEDGES 2^20.
static const u32 IDXSHIFT = 9;
static const word_t MAXEDGES = (word_t)1 << (EDGEBITS - IDXSHIFT);
static const u32 MAXSOLS = 4;

static void test_solver_graph(std::mt19937 &rng) {
    std::puts("Solver-sized compressed graph:");
    std::vector<std::vector<Edge>> sets;
    sets.push_back(make_edges(60000, true, rng));
    sets.push_back(make_edges(5000, false, rng));
    sets.push_back(make_edges(90000, true, rng));
    sets.push_back(make_edges(100, true, rng));
    sets.push_back(make_edges(0, false, rng));
    sets.push_back(make_edges(40000, true, rng));
    u32 sols = 0;
    run_rounds([] { return new graph<word_t>(MAXEDGES, MAXEDGES, MAXSOLS, IDXSHIFT); },
               sets, "compressed", &sols);
    check(sols >= 4, "every planted 42-cycle is found");
}

static void test_shared_memory_graph(std::mt19937 &rng) {
    std::puts("Shared-memory compressed graph:");
    // SIZEBITS = 29 - 17 = 12, so 4096 ids per side.
    const u32 compressbits = 17;
    const word_t maxedges = 8192;
    const word_t maxnodes = 4096;
    const size_t bytes = sizeof(word_t) * 2 * (size_t)maxnodes +
                         sizeof(graph<word_t>::link) * 2 * (size_t)maxedges +
                         2 * sizeof(word_t) * ((size_t)2 << (EDGEBITS - compressbits));
    std::vector<std::unique_ptr<char[]>> owned;
    std::vector<std::vector<Edge>> sets;
    for (int i = 0; i < 5; i++)
        sets.push_back(make_edges(1000 + 500 * i, i % 2 == 0, rng));
    u32 sols = 0;
    run_rounds([&] {
                   owned.emplace_back(new char[bytes]);
                   return new graph<word_t>(maxedges, maxnodes, MAXSOLS, compressbits,
                                            owned.back().get());
               },
               sets, "sharedmem", &sols);
    check(sols >= 3, "every planted 42-cycle is found");
}

static void test_node_overflow(std::mt19937 &rng) {
    std::puts("NODE OVERFLOW:");
    // SIZEBITS = 29 - 20 = 9, so only 512 ids per side.
    const u32 compressbits = 20;
    const word_t maxedges = 4096;
    const word_t maxnodes = 512;
    std::vector<std::vector<Edge>> sets;
    sets.push_back(make_edges(700, false, rng));  // overflows
    sets.push_back(make_edges(100, true, rng));   // fits
    sets.push_back(make_edges(800, true, rng));   // overflows
    sets.push_back(make_edges(50, true, rng));    // fits
    u32 sols = 0;
    std::fprintf(stderr, "(the NODE OVERFLOW messages below are expected)\n");
    run_rounds([&] { return new graph<word_t>(maxedges, maxnodes, MAXSOLS, compressbits); },
               sets, "overflow", &sols);
    check(sols >= 2, "planted 42-cycles after an overflow are found");

    // The solver counts graphs with an overflow from this counter.
    graph<word_t> g(maxedges, maxnodes, MAXSOLS, compressbits);
    g.reset();
    add_all(g, sets[1]);
    check(g.compressu->overflows + g.compressv->overflows == 0,
          "no overflow count for a graph that fits");
    g.reset();
    add_all(g, sets[0]);
    const size_t after_overflow = g.compressu->overflows + g.compressv->overflows;
    check(after_overflow > 0, "an overflowing graph is counted");
    g.reset();
    add_all(g, sets[3]);
    check(g.compressu->overflows + g.compressv->overflows == after_overflow,
          "the overflow count survives reset() and does not grow for a fitting graph");
}

static void test_uncompressed_graph(std::mt19937 &rng) {
    std::puts("Uncompressed graph:");
    const word_t maxnodes = 1 << 16;
    const word_t maxedges = 1 << 14;
    const size_t bytes = sizeof(word_t) * 2 * (size_t)maxnodes +
                         sizeof(graph<word_t>::link) * 2 * (size_t)maxedges;
    std::vector<std::vector<Edge>> sets;
    for (int i = 0; i < 4; i++)
        sets.push_back(make_edges(2000, true, rng));
    u32 sols = 0;
    run_rounds([&] { return new graph<word_t>(maxedges, maxnodes, MAXSOLS); },
               sets, "uncompressed", &sols);
    check(sols >= 4, "every planted 42-cycle is found");
    std::vector<std::unique_ptr<char[]>> owned;
    run_rounds([&] {
                   owned.emplace_back(new char[bytes]);
                   return new graph<word_t>(maxedges, maxnodes, MAXSOLS, owned.back().get());
               },
               sets, "uncompressed sharedmem", &sols);
}

// After the first full clear, reset() on a graph that owns its memory must
// only touch the entries the previous graph used: a marker past those
// entries survives it, but not reset_full(). A graph on shared memory always
// clears in full.
static void test_reset_is_sparse(std::mt19937 &rng) {
    std::puts("Sparse reset path:");
    graph<word_t> g(MAXEDGES, MAXEDGES, MAXSOLS, IDXSHIFT);
    g.reset();
    add_all(g, make_edges(1000, true, rng));
    const word_t marker = 7;
    g.adjlist[MAXEDGES - 1] = marker;
    g.adjlist[2 * MAXEDGES - 1] = marker;
    g.reset();
    check(g.adjlist[MAXEDGES - 1] == marker && g.adjlist[2 * MAXEDGES - 1] == marker,
          "reset() leaves entries past the used ids alone");
    g.reset_full();
    check(fully_reset(g), "reset_full() clears everything");

    const u32 compressbits = 17;
    const word_t maxedges = 8192;
    const word_t maxnodes = 4096;
    std::unique_ptr<char[]> bytes(new char[sizeof(word_t) * 2 * (size_t)maxnodes +
                                           sizeof(graph<word_t>::link) * 2 * (size_t)maxedges +
                                           2 * sizeof(word_t) * ((size_t)2 << (EDGEBITS - compressbits))]);
    graph<word_t> shared(maxedges, maxnodes, MAXSOLS, compressbits, bytes.get());
    shared.reset();
    add_all(shared, make_edges(100, true, rng));
    shared.adjlist[maxnodes - 1] = marker;
    shared.reset();
    check(shared.adjlist[maxnodes - 1] == graph<word_t>::NIL && fully_reset(shared),
          "reset() on shared memory clears everything");
}

// With asserts compiled out, an edge whose ids did not come from the
// compressors is dropped, and the next reset() clears in full. Only built
// with -DNDEBUG; otherwise add_edge would abort.
static void test_out_of_range_edge(std::mt19937 &rng) {
#ifdef NDEBUG
    std::puts("Out-of-range edge (NDEBUG):");
    graph<word_t> g(MAXEDGES, MAXEDGES, MAXSOLS, IDXSHIFT);
    g.reset();
    add_all(g, make_edges(1000, false, rng));
    const word_t nlinks = g.nlinks;
    g.add_edge(g.compressu->nnodes + 5, 0);
    check(g.nlinks == nlinks && g.adjlist[g.compressu->nnodes + 5] == graph<word_t>::NIL,
          "an out-of-range edge is not written");
    g.adjlist[MAXEDGES - 1] = 7;
    g.reset();
    check(fully_reset(g), "the next reset() clears everything");
    add_all(g, make_edges(1000, false, rng));
    g.adjlist[MAXEDGES - 1] = 7;
    g.reset();
    check(g.adjlist[MAXEDGES - 1] == 7, "the reset after that is sparse again");
#else
    (void)rng;
    std::puts("Out-of-range edge: skipped (build with -DNDEBUG)");
#endif
}

// Informational CPU-only timing of reset() per graph, at a typical
// post-trim edge count. Edge insertion is not timed.
static void time_resets(std::mt19937 &rng) {
    std::puts("CPU-only reset timing (informational):");
    const u32 rounds = 50;
    std::vector<Edge> edges = make_edges(60000, true, rng);
    graph<word_t> g(MAXEDGES, MAXEDGES, MAXSOLS, IDXSHIFT);
    g.reset_full();
    for (int sparse = 0; sparse < 2; sparse++) {
        double total_ms = 0;
        for (u32 i = 0; i < rounds; i++) {
            add_all(g, edges);
            auto start = std::chrono::steady_clock::now();
            if (sparse)
                g.reset();
            else
                g.reset_full();
            total_ms += std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - start).count();
        }
        std::printf("  %s reset after %zu edges: %.3f ms per graph\n",
                    sparse ? "sparse" : "full  ", edges.size(), total_ms / rounds);
    }
}

int main() {
    std::printf("GRAPH_UNION_SKIP=%d\n", GRAPH_UNION_SKIP);
    std::mt19937 rng(12345);
    test_solver_graph(rng);
    test_shared_memory_graph(rng);
    test_node_overflow(rng);
    test_uncompressed_graph(rng);
    test_reset_is_sparse(rng);
    test_out_of_range_edge(rng);
    time_resets(rng);
    if (failures) {
        std::printf("%d failure(s)\n", failures);
        return 1;
    }
    std::puts("All graph tests passed");
    return 0;
}
