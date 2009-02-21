(* threads.pml
 *
 * COPYRIGHT (c) 2008 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *)

structure Threads (*: sig

    type thread_id
    type vproc

    val exit : unit -> 'a

  end*) = struct

    structure PT = PrimTypes

    type thread_id = _prim(FLS.fls)
    type vproc = _prim(vproc)

    _primcode (

      (* create a thread *)
	define inline @create (f : fun(PT.unit / PT.exh -> PT.unit) / exh : PT.exh) : PT.fiber =
	    cont fiber (x : PT.unit) = 
	      let x : PT.unit =
	      (* in case of an exception, just terminate the fiber *)
		cont exh (exn : PT.exn) = return (UNIT)
		(* in *)
		  apply f (UNIT / exh)
	      (* in *)
		SchedulerAction.@stop ()
	    (* in *)
	    return (fiber)
	  ;

      (* spawn a new thread on the local vproc *)
	define inline @local-spawn (f : fun(PT.unit / PT.exh -> PT.unit) / exh : PT.exh) : FLS.fls =
	    let fiber: PT.fiber = @create (f / exh)
	    let fls : FLS.fls = FLS.@new (UNIT / exh)
	    (* in *)
	    do VProcQueue.@enqueue (fls, fiber / exh)
	    return (fls)
	  ;

      (* spawn a thread on a remote vproc *)
	define @remote-spawn (dst : vproc, f : fun (unit / exh -> unit) / exh : exh) : FLS.fls =
	    let fiber: PT.fiber = @create (f / exh)
	    let vprocId : int = VProc.@vproc-id (dst)
	    let fls : FLS.fls = FLS.@new-pinned (vprocId)
	    (* in *)
	    do VProcQueue.@enqueue-on-vproc (dst, fls, fiber)
	    return (fls)
	  ;

	define inline @thread-exit (x : PT.unit / exh : PT.exh) : any =
	    SchedulerAction.@stop ()
	  ;

      )

    val exit : unit -> 'a = _prim(@thread-exit)

  end

