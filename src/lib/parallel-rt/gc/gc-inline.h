/* gc-inline.h
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Inline operations for the GC.  See ../include/header-bits.h for header layout.
 */

#ifndef _GC_INLINE_H_
#define _GC_INLINE_H_

#include "manticore-rt.h"
#include "header-bits.h"
#include "heap.h"
#include "bibop.h"
#include "internal-heap.h"
#include "gc-scan.h"
#include "vproc.h"

/*! \for new header structure */
STATIC_INLINE int getID (Word_t hdr)
{
    return (uint16_t)((hdr >> TABLE_TAG_BITS) & 0x7FFF);
}

/*! \brief is a header tagged as a forward pointer? */
STATIC_INLINE bool isForwardPtr (Word_t hdr)
{
    return ((hdr & FWDPTR_TAG_MASK) == FWDPTR_TAG);
}

/*! \brief extract a forward pointer from a header */
STATIC_INLINE Word_t *GetForwardPtr (Word_t hdr)
{
    return (Word_t *)(hdr >> FWDPTR_TAG_BITS);
}

STATIC_INLINE Word_t MakeForwardPtr (Word_t hdr, Word_t *fp)
{
    return ((Word_t)fp) << FWDPTR_TAG_BITS;
}

/*! \brief return true if the value might be a pointer */
STATIC_INLINE bool isPtr (Value_t v)
{
    return (((Word_t)v & 0x3) == 0);
}

/*! \brief return true if the value is not a pointer */
STATIC_INLINE bool isNoPtr(Word_t hdr)
{
	return ((hdr & 0x1) == TABLE_TAG);
}

/*! \brief return true if the value is a pointer and is in the range covered
 * by the BIBOP.
 */
STATIC_INLINE bool isHeapPtr (Value_t v)
{
    return ((isPtr(v)) && ((Addr_t)v < (1l << ADDR_BITS)));
}

STATIC_INLINE bool isLimitPtr (Value_t v, MemChunk_t *cp)
{
    return ((Word_t)v == (cp->baseAddr+VP_HEAP_SZB - ALLOC_BUF_SZB));
}

STATIC_INLINE bool isMixedHdr (Word_t hdr)
{
    // NOTE: this must be updated anytime a new object type is added.
    return ((getID(hdr) > PROXY_TAG_VAL)  && (isNoPtr(hdr)));
}

STATIC_INLINE bool isVectorHdr (Word_t hdr)
{
    return ((getID(hdr) == VEC_TAG_VAL) && (isNoPtr(hdr)));
}

STATIC_INLINE bool isRawHdr (Word_t hdr)
{
    return ((getID(hdr) == RAW_TAG_VAL)  && (isNoPtr(hdr)));
}

STATIC_INLINE bool isStackHdr (Word_t hdr)
{
    return ((getID(hdr) == STACK_TAG_VAL)  && (isNoPtr(hdr)));
}

STATIC_INLINE bool isLinkedFrameHdr (Word_t hdr)
{
    return ((getID(hdr) == LINKFRAME_TAG_VAL)  && (isNoPtr(hdr)));
}

STATIC_INLINE bool isBitPatHdr (Word_t hdr)
{
    return ((getID(hdr) == BITPAT_TAG_VAL)  && (isNoPtr(hdr)));
}

STATIC_INLINE bool isProxyHdr (Word_t hdr)
{
    return ((getID(hdr) == PROXY_TAG_VAL)  && (isNoPtr(hdr)));
}

/* Return the length field of a header */
STATIC_INLINE uint32_t GetLength (Word_t hdr)
{
   return (hdr >> (TABLE_LEN_ID+TABLE_TAG_BITS)) & 0xFFFFFFFF;
}

/* Return the pattern field of a bit-pattern object header */
STATIC_INLINE uint16_t GetPattern (Word_t hdr)
{
   return (hdr >> (TABLE_LEN_LEN+TABLE_LEN_ID+TABLE_TAG_BITS));
}

/* return true if the given address is within the given address range */
STATIC_INLINE bool inAddrRange (Addr_t base, Addr_t szB, Addr_t p)
{
    return ((p - base) <= szB);
}

// This round-up routine is specific to assumptions about Manticore's heap.
// namely, it's word-size aligned by default. You must pass to this function
// the pointer into the to-space where objects are being forwarded.
// What is returned is a heap in a valid state where the forwarding
// pointer is now 16-byte aligned, with (*ptr)[-1] free.
//
// Implementation Note:
// Our GC must be able to parse the to-space in order to scan it for
// further pointers to forward, and it visits each object by relying
// on well-formed headers. Thus, to add padding between these objects,
// the padding must be parseable by the scanning routine, i.e., it
// must look like an allocated RAW object, which may be of size zero.
STATIC_INLINE void roundUpFwdPtr(Word_t** ptr, uint16_t powOfTwo) {
  const uint64_t wordSz = 8;
  if (powOfTwo == wordSz)
    return;

  assert(powOfTwo >= 16 && "any smaller and we can't do it or it's unneeded!");
  uint64_t addr = (uint64_t) *ptr;
  uint16_t remainder = addr % powOfTwo;

  if (remainder == 0)
    return;

  if (remainder % wordSz != 0)
    Die("we cannot align such an object.");

  uint64_t rawObjSz = (remainder / wordSz) - 1;
  (*ptr)[-1] = RAW_HDR(rawObjSz);

  addr += remainder;
  *ptr = (Word_t*) addr;
}

/*! \brief return the top of the used space in a memory chunk.
 *  \param vp the vproc that owns the chunk.
 *  \param cp the memory chunk.
 */
STATIC_INLINE Word_t *UsedTopOfChunk (VProc_t *vp, MemChunk_t *cp)
{
    if (vp->globAllocChunk == cp)
      /* NOTE: we must subtract WORD_SZB here because globNextW points to the first
       * data word of the next object (not the header word)!
       */
	return (Word_t *)(vp->globNextW - WORD_SZB);
    else
	return (Word_t *)(cp->usedTop);
}

//ForwardObject and isFromSpacePtr of GlobalGC
STATIC_INLINE bool isFromSpacePtr (Value_t p)
{
    return (isPtr(p) && (AddrToChunk(ValueToAddr(p))->sts == FROM_SP_CHUNK));

}

extern Value_t ForwardObjMinor (Value_t v, Word_t **nextW);
extern Value_t ForwardObjMajor (VProc_t *vp, Value_t v);
extern Value_t ForwardObjGlobal (VProc_t *vp, Value_t v);


#endif /* !_GC_INLINE_H_ */
