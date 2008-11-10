/* work-stealing-local-deques.h
 *
 * COPYRIGHT (c) 2008 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Local deques for the work stealing scheduler. 
 * 
 */

#ifndef _WORK_STEALING_LOCAL_DEQUES_H_
#define _WORK_STEALING_LOCAL_DEQUES_H_

#include "manticore-rt.h"
#include <stdio.h>
#include <string.h>
#include "vproc.h"
#include "value.h"

/* max size for the local deque */
#define WORK_STEALING_LOCAL_DEQUE_LEN               1024
/* maximum number of elements that can exist in the deque at one time, i.e., at all times it must be the case that
 *   hd - tl <= WORK_STEALING_LOCAL_DEQUE_MAX_ELTS
 */
#define WORK_STEALING_LOCAL_DEQUE_MAX_ELTS          128

/* local, work-stealing deque */
typedef struct {
  Word_t hd;                                           /* pointer to the head of the deque */
  Word_t tl;                                           /* pointer to the tail of the deque */
  Value_t elts[WORK_STEALING_LOCAL_DEQUE_LEN];         /* memory for the deque */
} WSLocalDeque_t;

/* list of worker deques */
struct WSLocalDeques_s {
  WSLocalDeque_t* hd;                 /* local deque */
  struct WSLocalDeques_s* tl;         /* rest of the list */
  Value_t live;                       /* if this field is false, then the local deque is garbage */
};

typedef struct WSLocalDeques_s WSLocalDeques_t;

Value_t M_WSAllocLocalDeque (int vprocId);
Value_t M_WSGetLocalDeque (WSLocalDeques_t* localDeques);
void M_WSFreeLocalDeque (WSLocalDeques_t* localDeques);

Value_t** M_WSAddLocalDequesToRoots (VProc_t* vp, Value_t** rp);
void M_WSInit (int nVProcs);

#endif /* _WORK_STEALING_LOCAL_DEQUES_H_ */
