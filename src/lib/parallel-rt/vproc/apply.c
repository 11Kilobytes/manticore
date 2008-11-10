/* apply.c
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 */

#include "manticore-rt.h"
#include "vproc.h"
#include "gc.h"
#include "value.h"
#include "request-codes.h"
#include "scheduler.h"
#include "heap.h"
#include "atomic-ops.h"
#include "work-stealing-local-deques.h"

extern RequestCode_t ASM_Apply (VProc_t *vp, Addr_t cp, Value_t arg, Value_t ep, Value_t rk, Value_t ek);
extern int ASM_Return;
extern int ASM_UncaughtExn;
extern int ASM_Resume;

/* \brief run a Manticore function f applied to arg.
 * \param vp the host vproc
 * \param f the Manticore function to apply
 * \param arg the Manticore value to apply \arg{f} to
 * \return the result of the application.
 */
Value_t ApplyFun (VProc_t *vp, Value_t f, Value_t arg)
{
  /* get the code and environment pointers for f */
    Addr_t cp = ValueToAddr (ValueToClosure(f)->cp);
    Value_t ep = ValueToClosure(f)->ep;

    RunManticore (vp, cp, arg, ep);

    return vp->stdArg;

} /* end of ApplyFun */


/* \brief Run Manticore code.
 * \param vp the host vproc
 * \param codeP the address of the code to run
 * \param arg the value of the standard argument register
 * \param envP the value of the standard environment-pointer register
 */
void RunManticore (VProc_t *vp, Addr_t codeP, Value_t arg, Value_t envP)
{
  /* allocate the return and exception continuation objects
   * in the VProc's heap.
   */
    Value_t retCont = AllocUniform(vp, 1, PtrToValue(&ASM_Return));
    Value_t exnCont = AllocUniform(vp, 1, PtrToValue(&ASM_UncaughtExn));

    while (1) {
#ifndef NDEBUG
	if (DebugFlg)
	    SayDebug("[%2d] ASM_Apply(-, %p, %p, %p, %p, %p)\n",
		vp->id, codeP, arg, envP, retCont, exnCont);
#endif
	RequestCode_t req = ASM_Apply (vp, codeP, arg, envP, retCont, exnCont);
	switch (req) {
	  case REQ_GC:
	  /* check to see if we actually need to do a GC, since this request
	   * might be from a pending signal.
	   */
	    if ((vp->limitPtr < vp->allocPtr) || vp->globalGCPending) {
	      /* request a minor GC; the protocol is that
	       * the stdCont register holds the return address (which is
	       * not in the heap) and that the stdEnvPtr holds the GC root.
	       *
	       * NOTE: the root set needs to be at least as large as the local roots and
	       * the roots coming from the local deque.
	       */
	        Value_t *roots[9 + WORK_STEALING_LOCAL_DEQUE_MAX_ROOTS], **rp;
		rp = roots;
		*rp++ = &(vp->stdEnvPtr);
		*rp++ = &(vp->currentFG);
		*rp++ = &(vp->actionStk);
		*rp++ = &(vp->rdyQHd);
		*rp++ = &(vp->rdyQTl);
		*rp++ = &(vp->entryQ);
		*rp++ = &(vp->secondaryQHd);
		*rp++ = &(vp->secondaryQTl);
		*rp++ = &(vp->schedCont);
		rp = M_WSAddLocalDequesToRoots(vp, rp);
		*rp++ = 0;
		MinorGC (vp, roots);
	    }

	  /* because some other process could have modified it, we must refresh the 
	   * limit pointer.
	   */
	    SetLimitPtr(vp);
	  /* check for pending signals. to guarantee responsiveness, we delay this check 
	   * until _after_ modifying the limit pointer.
	   */
	    Value_t sigPending = CompareAndSwapValue(&(vp->sigPending), M_TRUE, M_FALSE);

	  /* check for pending signals */
	    if ((sigPending == M_TRUE) && (vp->atomic == M_FALSE)) {
		Value_t resumeK = AllocUniform(vp, 3,
					       PtrToValue(&ASM_Resume),
					       vp->stdCont,
					       vp->stdEnvPtr);
		/* pass the signal to scheduling code in the BOM runtime.
		 * (more detailed comments in src/lib/basis/runtime/scheduler-utils.pml)
		 */
		envP = vp->schedCont;
		codeP = ValueToAddr(ValueToCont(envP)->cp);
		arg = resumeK;
	      /* clear the dead registers */
		retCont = M_UNIT;
		exnCont = M_UNIT;
	      /* mask signals, as the program will likely invoke scheduling code */
		vp->atomic = M_TRUE;
	    } else if (sigPending == M_TRUE) {
	      /* received a signal while in an atomic section */
	        vp->sigPending = M_TRUE;
	      /* invoke the stdCont to resume the program */
		codeP = ValueToAddr (vp->stdCont);
		envP = vp->stdEnvPtr;
	      /* clear the dead registers */
		arg = M_UNIT;
		retCont = M_UNIT;
		exnCont = M_UNIT;
	    } else {
	      /* setup the return from GC */
	      /* invoke the stdCont to resume the program */
		codeP = ValueToAddr (vp->stdCont);
		envP = vp->stdEnvPtr;
	      /* clear the dead registers */
		arg = M_UNIT;
		retCont = M_UNIT;
		exnCont = M_UNIT;
	    }	    
	    break;
	  case REQ_Return:	/* returning from a function call */
	    return;
	  case REQ_UncaughtExn:	/* raising an exception */
	    Die ("uncaught exception\n");
	  case REQ_Sleep:	/* make the VProc idle */
	    VProcWaitForSignal(vp);
	    envP = vp->stdCont;
	    assert(envP != M_NIL);
	    codeP = ValueToAddr(ValueToCont(envP)->cp);
	    arg = M_UNIT;
	    retCont = M_UNIT;
	    exnCont = M_UNIT;
	    break;
	default:
	  Die("unknown signal %d\n", req);
	}
    }

} /* end of RunManticore */
