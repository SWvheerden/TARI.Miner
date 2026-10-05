// Derived from tromp/cuckoo. SPDX-License-Identifier: GPL-2.0-or-later

#include <stdio.h>
#include <new>

// compressor for cuckaroo nodes where edgetrimming
// has left at most a fraction 2^-compressbits nodes in each partition
template <typename word_t>
class compressor {
public:
  u32 NODEBITS;
  u32 SHIFTBITS;
  u32 SIZEBITS;
  word_t SIZE;
  word_t SIZE2;
  word_t MASK;
  word_t MASK2;
  word_t nnodes;
  const word_t NIL = ~(word_t)0;
  word_t *nodes;
  // slots[i] is the hash slot holding id i, so reset_sparse() can clear
  // only the slots used since the last reset. Never part of the shared
  // bytes() layout.
  word_t *slots;
  bool sharedmem;
  // NODE OVERFLOW events since construction (never reset), so a caller can
  // tell whether one graph overflowed without parsing stderr.
  size_t overflows = 0;

  compressor(u32 nodebits, u32 compressbits, char *bytes) {
    NODEBITS = nodebits;
    SHIFTBITS = compressbits;
    SIZEBITS = NODEBITS-compressbits;
    SIZE = (word_t)1 << SIZEBITS;
    SIZE2 = (word_t)2 << SIZEBITS;
    nodes = new (bytes) word_t[SIZE2];
    slots = new word_t[SIZE];
    sharedmem = true;
    MASK = SIZE-1;
    MASK2 = SIZE2-1;
  }

  compressor(u32 nodebits, u32 compressbits) {
    NODEBITS = nodebits;
    SHIFTBITS = compressbits;
    SIZEBITS = NODEBITS-compressbits;
    SIZE = (word_t)1 << SIZEBITS;
    SIZE2 = (word_t)2 << SIZEBITS;
    nodes = new word_t[SIZE2];
    slots = new word_t[SIZE];
    sharedmem = false;
    MASK = SIZE-1;
    MASK2 = SIZE2-1;
  }

  // Owns heap memory, so copies would double-free.
  compressor(const compressor &) = delete;
  compressor &operator=(const compressor &) = delete;

  ~compressor() {
    if (!sharedmem)
      delete[] nodes;
    delete[] slots;
  }

  uint64_t bytes() {
    return (sizeof(word_t)*(size_t)SIZE2);
  }

  void reset() {
    memset(nodes, (char)NIL, (sizeof(word_t)*(size_t)SIZE2));
    nnodes = 0;
  }

  // Clears only the slots filled since the last reset. nodes must already
  // be fully cleared once by reset().
  void reset_sparse() {
    for (word_t i = 0; i < nnodes; i++)
      nodes[slots[i]] = NIL;
    nnodes = 0;
  }

  word_t compress(word_t u) {
    // Masked so a node outside NODEBITS cannot index past nodes (or be
    // replayed out of range by reset_sparse). Trimmed nodes are already
    // below 2^NODEBITS, so for them this changes nothing.
    word_t ui = (u >> SHIFTBITS) & MASK2;
    for (; ; ui = (ui+1) & MASK2) {
      word_t cu = nodes[ui];
      if (cu == NIL) {
        if (nnodes >= SIZE) {
          fprintf(stderr, "NODE OVERFLOW at %x\n", u);
          overflows++;
          return 0;
        }
        nodes[ui] = u << SIZEBITS | nnodes;
        slots[nnodes] = ui;
        return nnodes++;
      }
      if ((cu & ~MASK) == u << SIZEBITS) {
        return cu & MASK;
      }
    }
  }
};
