(* stm.pml
 *
 * COPYRIGHT (c) 2014 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Software Transactional Memory with partial aborts.
 *)

#define Read 0
#define Write 1

structure STM = (* :
    sig
	
*)
struct
(*
#define STMDebug
*)
#ifdef STMDebug
#define PDebug(msg)  do ccall M_Print(msg)  
#define PDebugInt(msg, v)  do ccall M_Print_Int(msg, v)  
#else
#define PDebug(msg) 
#define PDebugInt(msg, v)   
#endif
    _primcode(

        extern void * M_Print_Int(void *, int);

        typedef itemType = int; (*correponds to the above #define's*)
        typedef stamp = VClock.stamp;
        typedef tvar = ![any, long, ![stamp]]; (*contents, lock, version stamp*)

        typedef logItem = [tvar,      (*0: tvar operated on*)
                           itemType,  (*1: type of action performed (read or write)*)
                           stamp,     (*2: time stamp taken when action was performed*)
                           ![stamp],  (*3: pointer to current time stamp*)
                           any,       (*4: contents of local copy*)
                           cont()];   (*5: abort continuation*)

        define @new(x:any / exh:exh) : tvar = 
            let stamp : stamp = VClock.@bump(/exh)
            let tv : tvar = alloc(x, 0:long, (![long])alloc(stamp))
            let tv : tvar = promote(tv)
            return(tv)
        ;

        define @get(tv : tvar / exh:exh) : any = 
            fun enter() : any = 
                let v : any = #0(tv)
                fun chkLog(log : List.list) : Option.option = (*use local copy if available*)
                    case log
                        of CONS(hd:logItem, tl:List.list) =>
                            if Equal(#0(hd), tv)
                            then if I64Lt(#0(#3(hd)), #2(hd))
                                 then let res : Option.option = Option.SOME(#4(hd))
                                      return(res)
                                 else let k : cont() = #5(hd)
                                      throw k()
                            else apply chkLog(tl)
                        | nil => return (Option.NONE)
                    end
                let log : List.list = FLS.@get-key(LOG_KEY / exh)
                let localRes : Option.option = apply chkLog(log)
                case localRes
                    of Option.SOME(v:any) => return(v)
                     | Option.NONE => 
                        cont k() =
                            do FLS.@set-key(LOG_KEY, log / exh) (*reset log*)
                            apply enter()
                        let stamp : stamp = VClock.@bump(/exh)
                        let current : any = #0(tv)
                        let item : logItem = alloc(tv, Read, stamp, #2(tv), current, k)
                        let newLog : List.list = CONS(item, log)
                        do FLS.@set-key(LOG_KEY, newLog / exh)
                        return(current)
                end
            apply enter()
        ;

        define @put(arg:[tvar, any] / exh:exh) : unit =
            fun enter() : unit = 
                let tv : tvar = #0(arg)
                let v : any = #1(arg)
                fun mkItem(log:List.list) : logItem = 
                    case log 
                        of CONS(hd:logItem, tl:List.list) =>
                            if Equal(#0(hd), tv)
                            then let item : logItem = alloc(tv, Write, #2(hd), #2(tv), v, #5(hd))
                                 return(item)
                            else apply mkItem(tl)
                         |nil => let stamp : stamp = VClock.@bump(/exh)
                                 cont k () = 
                                    do FLS.@set-key(LOG_KEY, log / exh)
                                    apply enter()
                                 let item : logItem = alloc(tv, Write, stamp, #2(tv), v, k)
                                 return(item)
                    end
                let log : List.list = FLS.@get-key(LOG_KEY / exh)
                let item : logItem = apply mkItem(log)
                let newLog : List.list = CONS(item, log)
                do FLS.@set-key(LOG_KEY, newLog / exh)
                return(UNIT)
            apply enter()
        ;

        define @commit(/exh:exh) : () = 
            let stamp : stamp = VClock.@bump(/exh)
            fun release(locks : List.list) : () = 
                case locks 
                    of CONS(hd:logItem, tl:List.list) =>
                        let tv:tvar = #0(hd)
                        do #1(tv) := 0:long
                        apply release(tl)
                     | nil => return()
                end
            fun acquire(log:List.list) : List.list = 
                case log 
                    of CONS(hd:logItem, tl:List.list) =>
                        let res : List.list = apply acquire(tl)
                        let abortK : cont() = #5(hd)
                        if I32Eq(#1(hd), Read)
                        then let currentStamp : ![stamp] = #3(hd)
                             if I64Lt(#0(currentStamp), #2(hd))
                             then return(res)
                             else do apply release(res)
                                  throw abortK()
                        else let tv : tvar = #0(hd)
                             let lockRes : long = CAS(&1(tv), 0:long, stamp) (*lock it*)
                             if I64Eq(#1(tv), stamp)
                             then return(CONS(hd, res))
                             else do apply release(res)
                                  throw abortK()
                     |nil => return(nil)
                end               
            fun update(writes:List.list) : () = 
                case writes
                    of CONS(hd:logItem, tl:List.list) =>
                        if I64Eq(#0(#3(hd)), stamp)
                        then return()
                        else let tv : tvar = #0(hd)
                             let newContents : any = #4(hd)
                             let newContents : any = promote(newContents)
                             do #0(tv) := newContents         (*update contents*)
                             do #0(#2(tv)) := stamp           (*update version stamp*)
                             do apply update(tl)              (*update remaining*)
                             do #1(tv) := 0:long                   (*unlock*)
                             return()
                     | nil => return()
                end
            let log : List.list = FLS.@get-key(LOG_KEY / exh)
            let writes : List.list = apply acquire(log)
            apply update(writes)
        ;
        
        define @atomic(f:fun(unit / exh -> any) / exh:exh) : any = 
            let fls : FLS.fls = FLS.@get()
            let in_trans : ![bool] = FLS.@get-key(IN_TRANS / exh)
            if (#0(in_trans))
            then PDebug("entering nested transactions\n") apply f(UNIT/exh)
            else do FLS.@set-key(LOG_KEY, nil / exh)  (*initialize STM log*)
                 do #0(in_trans) := true           
                 let res : any = apply f(UNIT/exh)
                 do @commit(/exh)
                 do #0(in_trans) := false
                 return(res)
        ;            

    )

    	type 'a tvar = _prim(tvar)
    	val atomic : (unit -> 'a) -> 'a = _prim(@atomic)
    val get : 'a tvar -> 'a = _prim(@get)
    val new : 'a -> 'a tvar = _prim(@new)
    val put : 'a tvar * 'a -> unit = _prim(@put)
end













 
