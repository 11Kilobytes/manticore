(* lrope-ops.sml
 *
 * Ropes with lists at the leaves.
 *
 * (c) 2008 Manticore Group (http://manticore.cs.uchicago.edu)
 *)

structure LRopeOps =
  struct

    structure F = Future1
    structure PT = PrimTypes
    structure L = List

    datatype 'a lrope =
	     LEAF of (int * 'a L.list)
	   | CAT of (int * int * 'a lrope * 'a lrope)

    _primcode(

      (* For mapping a function over the elements of the leaves of a lrope in parallel. *)
      define @lrope-map (f : fun (any / PT.exh -> any), r : lrope / exh : PT.exh) : lrope =

	fun m (r : lrope / ) : lrope = 
	  case r
	    of LEAF(len:[int], data:L.list) => 
		 let newData : L.list = PrimList.@map (f, data / PT.exh)
		 let newLeaf : lrope = LEAF(#0(len), newData)
		 (* do ccall M_Print("leaf size \000")
		 do ccall M_PrintInt(len)
		 do ccall M_Print("\n\000") *)
		 return (newLeaf)
	     | CAT(len:[int], depth:[int], r1:lrope, r2:lrope) =>
		 fun th (u : unit / exh : PT.exh) : lrope = apply m (r2)
		 let fut : future = F.@future (th / exh)
		 let newR1 : lrope = apply m (r1)
		 let newR2 : lrope = F.@touch (fut / exh)
		 let newR : lrope = CAT (len, depth, newR1, newR2)
		 return (newR)
	  end (* case *)
	  (* end definition of m *)

	let newR : lrope = apply m (r)
	return (newR)
      ;

      define @lrope-map-wrapper (args : [(* f *) fun (any / PT.exh -> any),
				       (* r *) lrope]  / exh : PT.exh) : lrope =

	let f : fun (any / PT.exh -> any) = #0(args)
	let r : lrope = #1(args)

	@lrope-map(f, r / exh)
      ;

      define @lrope-length-int (r : lrope / exh : PT.exh) : int =
	case r
	 of LEAF(n : [int], _ : list) => return (#0(n))
	  | CAT (n : [int], d : [int], _ : lrope, _ : lrope) => return (#0(n))
	end
      ;

    (* A subscript operator for lropes (which were parrays in the surface program). *)
      define @lrope-sub (r : lrope, n : int / exh : PT.exh) : any =

	fun sub (r : lrope, n : int / ) : any =
	  case r
	    of LEAF (len:[int], data:L.list) =>
		 let foundIt : PT.bool = I32Lt (n, #0(len))
		 if foundIt
		   then 
		     let res2 : any = PrimList.@nth(data, n / exh)
		     return (res2)
		   else
		     do assert(PT.FALSE)
		     return(enum(0):any)
	     | CAT (len:[int], depth:[int], r1:lrope, r2:lrope) =>
		 let leftLen : int = @lrope-length-int (r1 / exh)
		 let onTheLeft : PT.bool = I32Lt (n, leftLen)
		   if onTheLeft
		     then
		       let res3 : any = apply sub (r1, n)
		       return (res3)
		     else
		       let newN : int = I32Sub (n, leftLen)
		       let res4 : any = apply sub (r2, newN)
		       return (res4)
	    end

	let res5 : any = apply sub (r, n)
	return (res5)
      ;

      define @lrope-sub-wrapper (arg : [lrope, PT.ml_int] / exh : PT.exh) : any =
	let r : lrope     = #0(arg)
	let mln : ml_int = #1(arg)
	let n : int      = unwrap(mln)
	@lrope-sub(r, n / exh)
      ;

    )

    val lropeMap : (('a -> 'b) * 'a lrope) -> 'b lrope = _prim(@lrope-map-wrapper)
    val lropeSub : ('a lrope * int) -> 'a

  end
