structure NoRecFF = 
struct

#define READ_SET_BOUND 20

    structure RS = FFReadSet

	_primcode(
		(*I'm using ![any, long, long] as the type
		 * for tvars so that the typechecker will treat them
		 * as the same type as the other STM implementations.
		 * However, only the first element is ever used*)
		typedef tvar = FullAbortSTM.tvar;
		typedef stamp = VClock.stamp;

        extern void M_PruneRemSetAll(void*, long, void*);		

		define @new(x:any / exh:exh) : tvar =
			let tv : [any] = alloc(x)
			let tv : [any] = promote(tv)
			let tv : tvar = (tvar) tv
			return(tv)
		;

		  define inline @get-stamp(/exh:exh) : stamp =
			fun stampLoop() : long = 
				let current : long = VClock.@get(/exh)
				let lastBit : long = I64AndB(current, 1:long)
				if I64Eq(lastBit, 0:long)
				then return(current)
				else do Pause() apply stampLoop()
			let stamp : stamp = apply stampLoop()
			return(stamp)
		;

		define @ffNoRecGet(tv : tvar / exh:exh) : any = 
			let in_trans : [bool] = FLS.@get-key(IN_TRANS / exh)
            do 	
            	if(#0(in_trans))
               	then return()
               	else 
               		do ccall M_Print("Trying to read outside a transaction!\n")
                  	let e : exn = Fail(@"Reading outside transaction\n")
                    throw exh(e)
            let myStamp : ![stamp, int, int, long] = FLS.@get-key(STAMP_KEY / exh)
            let readSet : RS.read_set = FLS.@get-key(READ_SET / exh)
            let writeSet : RS.item = FLS.@get-key(WRITE_SET / exh)
            fun chkLog(writeSet : RS.item) : Option.option = (*use local copy if available*)
                case writeSet
                   of NoRecOrderedReadSet.Write(tv':tvar, contents:any, tl:RS.item) =>
                        if Equal(tv', tv)
                        then return(Option.SOME(contents))
                        else apply chkLog(tl)
                    | NoRecOrderedReadSet.NilItem => return (Option.NONE)
                end
            cont retK(x:any) = return(x)
            do RS.@fast-forward(readSet, writeSet, tv, retK, myStamp / exh)
            let localRes : Option.option = apply chkLog(writeSet)
            case localRes
               of Option.SOME(v:any) => return(v)
                | Option.NONE =>
                	fun getLoop() : any = 
                        let v : any = #0(tv)
                		let t : long = VClock.@get(/exh)
                		if I64Eq(t, #0(myStamp))
                		then return(v)
                		else
                			do RS.@eager-validate(readSet, myStamp / exh)
                			apply getLoop()
                	let current : any = apply getLoop()
                    let kCount : int = NoRecOrderedReadSet.@getNumK(readSet)
                    (*TODO: rearrange these branches so that we check our counter first and then if we have enough room for another k*)
                    if I32Lt(kCount, READ_SET_BOUND)    (*still have room for more*)
                    then 
                        let captureCount : int = FLS.@get-counter()
                        if I32Eq(captureCount, 0)  (*capture a continuation*)
                        then 
                            do NoRecOrderedReadSet.@insert-with-k(tv, current, retK, writeSet, readSet, myStamp / exh)
                            let captureFreq : int = FLS.@get-counter2()
                            do FLS.@set-counter(captureFreq)
                            return(current)
                        else (*don't capture a continuation*)
                            do FLS.@set-counter(I32Sub(captureCount, 1))
                            do NoRecOrderedReadSet.@insert-without-k(tv, current, readSet, myStamp / exh)
                            return(current)
                    else 
                        do RS.@filterRS(readSet, myStamp / exh)
                        do NoRecOrderedReadSet.@insert-without-k(tv, current, readSet, myStamp / exh)
                        let captureFreq : int = FLS.@get-counter2()
                        let newFreq : int = I32Mul(captureFreq, 2)
                        do FLS.@set-counter(I32Sub(newFreq, 1))
                        do FLS.@set-counter2(newFreq)
                        return(current)
            end
		;

		define @put(arg:[tvar, any] / exh:exh) : unit =
            let in_trans : [bool] = FLS.@get-key(IN_TRANS / exh)
            do if(#0(in_trans))
               then return()
               else do ccall M_Print("Trying to write outside a transaction!\n")
                    let e : exn = Fail(@"Writing outside transaction\n")
                    throw exh(e)
            let tv : tvar = #0(arg)
            let v : any = #1(arg)
            let writeSet : RS.item = FLS.@get-key(WRITE_SET / exh)
            let newWriteSet : RS.item = NoRecOrderedReadSet.Write(tv, v, writeSet)
            do FLS.@set-key(WRITE_SET, newWriteSet / exh)
            return(UNIT)
        ;

        define @commit(stamp : ![stamp, int, int, long] /exh:exh) : () =
        	let readSet : RS.read_set = FLS.@get-key(READ_SET / exh)
        	let writeSet : RS.item = FLS.@get-key(WRITE_SET / exh)
        	let counter : ![long] = VClock.@get-boxed(/exh)
        	fun lockClock() : () = 
        		let current : stamp = #0(stamp)
        		let old : long = CAS(&0(counter), current, I64Add(current, 1:long))
        		if I64Eq(old, current)
        		then return()
        		else
        			do RS.@commit-validate(readSet, stamp / exh)
        			apply lockClock()
        	do apply lockClock()
        	fun writeBack(ws:RS.item) : () = 
        		case ws 
        		   of NoRecOrderedReadSet.NilItem => return()
        			| NoRecOrderedReadSet.Write(tv:tvar, x:any, next:RS.item) => 
        				let x : any = promote(x)
        				do #0(tv) := x
        				apply writeBack(next)
        		end
            fun reverseWS(ws:RS.item, new:RS.item) : RS.item = 
                case ws 
                   of NoRecOrderedReadSet.NilItem => return(new)
                    | NoRecOrderedReadSet.Write(tv:tvar, x:any, next:RS.item) => apply reverseWS(next, NoRecOrderedReadSet.Write(tv, x, new))
                end
            let writeSet : RS.item = apply reverseWS(writeSet, NoRecOrderedReadSet.NilItem)
        	do apply writeBack(writeSet)
        	do #0(counter) := I64Add(#0(stamp), 2:long) (*unlock clock*)
        	return()
        ;

		define @atomic(f:fun(unit / exh -> any) / exh:exh) : any = 
            let in_trans : ![bool] = FLS.@get-key(IN_TRANS / exh)
            if (#0(in_trans))
            then apply f(UNIT/exh)
            else 
            	let stampPtr : ![stamp, int, int, long] = FLS.@get-key(STAMP_KEY / exh)
                do FLS.@set-key(FF_KEY, enum(0) / exh)
                cont enter() = 
                    let rs : RS.read_set = RS.@new()
                    do FLS.@set-key(READ_SET, rs / exh)  (*initialize STM log*)
                    do FLS.@set-key(WRITE_SET, NoRecOrderedReadSet.NilItem / exh)
                    let stamp : stamp = @get-stamp(/exh)
                    do #0(stampPtr) := stamp
                    do #0(in_trans) := true
                    cont abortK() = BUMP_FABORT do #0(in_trans) := false throw enter()
                    do FLS.@set-key(ABORT_KEY, abortK / exh)
                    cont transExh(e:exn) = 
                    	do ccall M_Print("Warning: exception raised in transaction\n")
                        throw exh(e)
                    let res : any = apply f(UNIT/transExh)
                    do @commit(stampPtr / transExh)
                    let vp : vproc = host_vproc
                    do #0(in_trans) := false
                    do FLS.@set-key(READ_SET, NoRecOrderedReadSet.NilItem / exh)
                    do FLS.@set-key(WRITE_SET, NoRecOrderedReadSet.NilItem / exh)
                    do FLS.@set-key(FF_KEY, enum(0) / exh)
		            do ccall M_PruneRemSetAll(vp, #3(stampPtr), "@atomic")
                    return(res)
                throw enter()
      	;

	    define @abort(x : unit / exh : exh) : any = 
	        let e : cont() = FLS.@get-key(ABORT_KEY / exh)
	        throw e();

	)

	type 'a tvar = 'a FullAbortSTM.tvar
    val get : 'a tvar -> 'a = _prim(@ffNoRecGet)
    val new : 'a -> 'a tvar = _prim(@new)
    val atomic : (unit -> 'a) -> 'a = _prim(@atomic)
    val put : 'a tvar * 'a -> unit = _prim(@put)
    val abort : unit -> 'a = _prim(@abort)
  
    val _ = Ref.set(STMs.stms, ("ffnorec", (get,put,atomic,new,abort))::Ref.get STMs.stms)
end













