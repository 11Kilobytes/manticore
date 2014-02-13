(* spec-par.pml
 *
 * COPYRIGHT (c) 2013 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * support for speculative parallelism that provides runtime support for 
 * rolling back ivars in the event an exception is raised
 *)

#include "spin-lock.def"

structure SpecPar (*: sig
    val spec : (unit -> 'a * unit -> 'b) -> ('a, 'b)
    end*) = struct

    val pLock = 0

    fun printLock() = pLock

    _primcode(

        #define PDebug(msg) do ccall M_Print(msg)  
        
        #define PDebugInt(msg, v) do ccall M_Print_Int(msg, v) 

        typedef tid = ![
            int,           (*Size of the list*)
            List.list];    (*thread id*)        

        define @printVP(x:unit/exh:exh) : unit = 
            let vp : vproc = host_vproc
            let vp : int = VProc.@vproc-id(vp)
            PDebugInt("Executing on vproc: %d\n", vp)
            return(UNIT)
        ;

        define @getKey = FLS.getKey;
        define @find = FLS.find;

        define @getPrintLock = printLock;

        define @runningOn(x:unit/exh:exh) : unit = 
            let vp : vproc = host_vproc
            let vp : int = VProc.@vproc-id(vp)
            PDebugInt("Executing on vproc: %d\n", vp)
            return(UNIT)
        ;
        
        define @printTID(x : unit / exh : exh) : unit = 
            let tid : any = FLS.@get-key(alloc(TID_KEY) / exh)
            let tid : tid = (tid) tid
            PDebug("TID: ")
            fun helper(tid : List.list) : () = 
                case tid
                    of CONS(hd : [int], tail : List.list) => 
                        do apply helper(tail)
                        PDebugInt("%d, ", #0(hd))
                        return()
                    | nil => return()
                end
            do apply helper(#1(tid))
            PDebug("\n")
            return(UNIT)
        ;

        define @tidToString(/exh : exh) : PrimTypes.ml_string = 
            let tid : any = FLS.@get-key(alloc(TID_KEY)/exh)
            let tid : tid = (tid) tid
            fun helper(tid : List.list) : PrimTypes.ml_string = 
                case tid 
                    of CONS(hd : [int], tail : List.list) => 
                        let s : PrimTypes.ml_string = Int.@to-string(hd/exh)
                        let l : PrimTypes.ml_string = apply helper(tail)
                        let l : List.list = CONS(s, CONS(", ", CONS(l, nil)))
                        let s : PrimTypes.ml_string = String.@string-concat-list(l/exh)
                        return(s)
                     | nil => return("")
                end
            apply helper(#1(tid))
        ;

        define @pSpec(arg : [fun(unit / exh -> any), fun(unit / exh -> any)] / exh : exh):[any,any] = 
            let a : fun(unit / exh -> any) = #0(arg)
            let b : fun(unit / exh -> any) = #1(arg)
            let dummy : any = enum(0) : any
            let res : ![any,any] = alloc(dummy, dummy)
            let count : ![int] = alloc(0)
            let count : ![int] = promote(count)
            let cbl : Cancelation.cancelable = Cancelation.@new(UNIT/exh)
            let writeList : ![List.list] = alloc(nil)
            let writeList : ![List.list] = promote(writeList)
            let parentTID : any = FLS.@get-key(alloc(TID_KEY) / exh)
            let parentTID : tid = (tid) parentTID
            let specTID : tid = alloc(I32Add(#0(parentTID), 1), CONS((any) alloc(2), #1(parentTID)))
            let specTID : tid = promote(specTID)
            let parentWriteList : any = FLS.@get-key(alloc(WRITES_KEY) / exh)
            let parentWriteList : ![List.list] = promote((![List.list]) parentWriteList)
            cont execContinuation(s : ![any, any]) = 
                do FLS.@set-key(alloc(alloc(TID_KEY), parentTID) / exh)
                do FLS.@set-key(alloc(alloc(WRITES_KEY), parentWriteList) / exh)
                return(s)
            cont slowClone(_ : unit) = (*work that can potentially be stolen*)
                let vp : vproc = host_vproc let vp : int = VProc.@vproc-id(vp)
                do FLS.@set-key(alloc(alloc(WRITES_KEY), writeList) / exh)
                do FLS.@set-key(alloc(alloc(TID_KEY), specTID) / exh)
                do FLS.@set-key(alloc(alloc(SPEC_KEY), alloc(true)) / exh)  (*Put in spec mode*)
                let res : ![any,any] = promote(res)
                let v_1 : any = apply b(UNIT / exh)
                let v_1' : any = promote(v_1)
                do #1(res) := v_1'
                let updated : int = I32FetchAndAdd(&0(count), 1)
                if I32Eq(updated, 0)
                then SchedulerAction.@stop()
                else do IVar.@commit(#0(writeList)/exh)
                     throw execContinuation(res)
            let thd : ImplicitThread.thread = ImplicitThread.@new-cancelable-thread(slowClone, cbl / exh)
            do ImplicitThread.@spawn-thread(thd / exh)
            cont newExh(e : exn) = 
                let removed : Option.option = ImplicitThread.@remove-thread(thd/exh)
                if NotEqual(removed, UNIT)(*not stolen*)
                then PDebug("Exception raised, but speculative thread was not stolen\n")
                     throw exh(e)  (*simply propogate exception*)
                else PDebug("Exception raised and speculative thread was stolen\n")
                     let _ : unit = Cancelation.@cancel(cbl / exh)
                     let writes : List.list = #0(writeList)
                     do IVar.@rollback(writes / exh)
                     throw exh(e)
            let ws : ![List.list] = alloc(nil)
            let ws : ![List.list] = promote(ws)
            do FLS.@set-key(alloc(alloc(WRITES_KEY), ws) / exh)
            let parentTID : tid = (tid) parentTID
            let newTID : tid = alloc(I32Add(#0(parentTID), 1), CONS((any) alloc(1), #1(parentTID)))
            do FLS.@set-key(alloc(alloc(TID_KEY), newTID) / exh)    (*Now executing as "left child"*)
            let v_0 : any = apply a(UNIT/newExh)
            let removed : Option.option = ImplicitThread.@remove-thread(thd/exh)
            case removed 
                of Option.SOME(t : ImplicitThread.thread) => 
                         let vp : vproc = host_vproc let vp : int = VProc.@vproc-id(vp)
                         PDebugInt("Speculative computation was not stolen (vp = %d)\n", vp)
                         let v_1 : any = apply b(UNIT/exh)
                         let res : ![any, any] = alloc(v_0, v_1)
                         throw execContinuation(res)
                  |Option.NONE => let res : ![any, any] = promote(res) 
                                  let vp : vproc = host_vproc let vp : int = VProc.@vproc-id(vp)
                                  PDebugInt("Speculative computation was stolen on vp %d\n", vp)  
                                  let v_0' : any = promote(v_0)
                                  do #0(res) := v_0'
                                  let updated : int = I32FetchAndAdd(&0(count), 1)
                                  if I32Eq(updated, 0)
                                  then SchedulerAction.@stop()
                                  else do IVar.@commit(#0(writeList)/exh)
                                       throw execContinuation(res)
           end
        ;
        
    )

    val runningOn : unit -> unit = _prim(@runningOn)
    val spec : ((unit -> 'a) * (unit -> 'b)) -> ('a * 'b) = _prim(@pSpec)
    val printTID : unit -> unit = _prim(@printTID)
    val printVP : unit -> unit = _prim(@printVP)

    
end

