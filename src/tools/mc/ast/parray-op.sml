(* parray-op.sml
 *
 * COPYRIGHT (c) 2011 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Operations on flattening operators.
 *
 * Supporting documents in 
 * /path/to/manti-papers/papers/notes/amsft
 *)

structure PArrayOp = struct

  structure A = AST
  structure B = Basis
  structure T = Types

  structure TU = TypeUtil

(* structure AU = ASTUtil -- can't include ASTUtil, cyclic deps *)

  val commas = String.concatWith ","

  infixr -->
  fun domTy --> rngTy = T.FunTy (domTy, rngTy)

  infixr **
  fun t1 ** t2 = T.TupleTy [t1, t2]

  fun `f x = (fn y => f (x, y))

  local
    fun groundCon c = List.exists (`TyCon.same c) B.primTycs
  in
    fun isGroundTy (T.ConTy ([], c)) = groundCon c
      | isGroundTy (unitTy as T.TupleTy []) = true
      | isGroundTy _ = false
  end (* local *)

  local
    fun tos s t = String.concat [s, "_{", TU.toString t, "}"]
    fun $f xs = List.map f xs
  in
    val toString : A.parray_op -> string = let
      fun ps (A.PSub_Nested t) = tos "PSub_Nested" t
	| ps (A.PSub_Flat t) = tos "PSub_Flat" t
	| ps (A.PSub_Tuple os) = 
	    String.concat ["PSub_Tuple[",
			   commas ($ps os),
			   "]"]
      fun pop (A.PA_Length t) = tos "PA_Length" t
	| pop (A.PA_Sub s) = "PA_Sub_{" ^ ps s ^ "}"
	| pop (A.PA_Tab t) = tos "PA_Tab" t
	| pop (A.PA_TabFTS t) = tos "PA_TabFTS" t
	| pop (A.PA_TabTupleFTS ts) = 
            "PA_TabTupleFTS_{" ^ commas ($TU.toString ts) ^ "}"
	| pop (A.PA_Map t) = tos "PA_Map" t
	| pop (A.PA_MapSP t) = tos "PA_MapSP" t
	| pop (A.PA_Reduce t) = tos "PA_Reduce" t				  
	| pop (A.PA_SegReduce t) = tos "PA_SegReduce" t
	| pop (A.PA_Range t) = tos "PA_Range" t
	| pop (A.PA_App t) = tos "PA_App" t
	| pop (A.PA_TabHD (d, t)) = tos ("PA_TabHD_" ^ Int.toString d) t
	| pop (A.PA_PairMap t) = tos "PA_PairMap" t
      in
        pop      
      end
  end (* local *)

  val typeOf : A.parray_op -> T.ty = let
    fun mk d r = T.FunTy (T.TupleTy [d, B.intTy], r)
    fun ps (A.PSub_Nested t) = (case t
          of T.FArrayTy (t', T.NdTy n) => mk t (T.FArrayTy (t', n))
	   | _ => raise Fail ("ps " ^ TU.toString t)
          (* end case *))
      | ps (A.PSub_Flat t) = (case t
          of T.FArrayTy (t', T.LfTy) => mk t t'
	   | _ => raise Fail ("ps " ^ TU.toString t)
          (* end case *))
      | ps (A.PSub_Tuple os) = let
          val ts = List.map ps os
	  val ds = List.map TU.domainType ts
	  fun fst (T.TupleTy [t1, t2]) = t1
	    | fst _ = raise Fail "compiler bug"
	  val fs = List.map fst ds
	  val rs = List.map TU.rangeType ts
          in
	    mk (T.TupleTy fs) (T.TupleTy rs)
	  end
    fun pop (A.PA_Length t) = (t --> B.intTy)
      | pop (A.PA_Sub s) = ps s
      | pop (A.PA_Tab eltTy) = let
	  val domTy = T.TupleTy [B.intTy, B.intTy --> eltTy]
	  val rngTy = T.FArrayTy (eltTy, T.LfTy)
          in
	    domTy --> rngTy
	  end
      | pop (A.PA_TabFTS eltTy) = let
          val i = B.intTy
          val domTy = T.TupleTy [i, i, i, i --> eltTy]
	  val rngTy = T.FArrayTy (eltTy, T.LfTy)
          in
	    domTy --> rngTy
	  end
      | pop (A.PA_TabTupleFTS ts) = let
          val i = B.intTy
	  val eltTy = T.TupleTy ts
	  val domTy = T.TupleTy [i, i, i, i --> eltTy]
	  val rngTy = T.TupleTy (List.map (fn t => T.FArrayTy (t, T.LfTy)) ts)
          in
	    domTy --> rngTy
	  end
      | pop (A.PA_Map t) = (case t
          of T.FunTy (domTy, rngTy) => (case domTy
               of T.TupleTy ts => raise Fail "todo"
		| T.ConTy (ts, c) => 
                    if isGroundTy domTy then let
                      fun f t = T.FArrayTy (t, T.LfTy)
                      in
                        (domTy --> rngTy) --> ((f domTy) --> (f rngTy))
		      end
		    else
		      raise Fail ("todo " ^ TU.toString t)
		| _ => raise Fail ("todo " ^ TU.toString t)
               (* end case *))
	   | _ => raise Fail ("unexpected ty " ^ TU.toString t)
          (* end case *))	
      | pop (A.PA_PairMap t) = (case t
          of T.FunTy (domTy, rngTy) => (case domTy
               of T.TupleTy [t1, t2] =>
                    if isGroundTy t1 andalso isGroundTy t2 then let
                      fun f t = T.FArrayTy (t, T.LfTy)
                      val domTy' = T.TupleTy [domTy, f t1, f t2]
	              in
                        domTy' --> (f rngTy)
	              end
		    else
	              raise Fail ("todo " ^ TU.toString t)
		| _ => raise Fail ("todo " ^ TU.toString t)
               (* end case *))
	   | _ => raise Fail ("unexpected ty " ^ TU.toString t)
          (* end case *))
      | pop (A.PA_Reduce t) =
          if isGroundTy t then let
            val ta = T.FArrayTy (t, T.LfTy)
            in
              (t --> t) --> (t --> (ta --> t))
            end
          else
	    raise Fail ("todo: reductions on " ^ TU.toString t)
      | pop (A.PA_SegReduce t) =
          if isGroundTy t then let
            val operTy = (t ** t) --> t
	    val fty = T.FArrayTy (t, T.NdTy T.LfTy)
            in
              (T.TupleTy [operTy, t, fty]) --> T.FArrayTy (t, T.LfTy)
	    end
	  else
	    raise Fail ("in PArrayOp.typeOf: SegReduce of a non ground type "
			^ TU.toString t)
      | pop (A.PA_MapSP t) = let
          fun fty t = T.FArrayTy (t, T.NdTy T.LfTy)
          in case t
	    of T.FunTy (a, b) =>
                (case a
		   of T.TupleTy [a1, a2] =>
                        T.FunTy (T.TupleTy [t, T.TupleTy [fty a1, fty a2]], fty b)
		    | _ => raise Fail "todo"
                   (* end case *))
	     | _ => raise Fail ("unexpected ty " ^ TU.toString t)
            (* end case *)
	  end
      | pop (A.PA_Range t) = let
          val _ = if TU.same (t, B.intTy) then () 
		  else raise Fail ("not int: " ^ TU.toString t)
          in
	    (T.TupleTy [B.intTy, B.intTy, B.intTy]) --> (T.FArrayTy (B.intTy, T.LfTy))
                                                        (* (B.parrayTy B.intTy) *)
	  end
      | pop (A.PA_App eltTy) = let
          val domTy = eltTy --> B.unitTy
	  val rngTy = T.FArrayTy (eltTy, T.LfTy) --> B.unitTy
          in
	    domTy --> rngTy
	  end
      | pop (A.PA_TabHD (dim, eltTy)) = let
	  fun dup (n, x) = List.tabulate (n, fn _ => x)
          fun appn (n, f) x = let
            fun lp (0, acc) = acc
	      | lp (n, acc) = lp (n-1, f acc)
            in
	      if (n<0) then x else lp (n, x)
	    end
	  val i = B.intTy
	  val fTy = T.TupleTy (dup (dim, i)) --> eltTy
          val domTy = T.TupleTy (dup (dim*3, i) @ [fTy])
	  val shape = appn (dim-1, T.NdTy) T.LfTy
	  val rngTy = T.FArrayTy (eltTy, shape)
          in
	    domTy --> rngTy
	  end
    in
      pop
    end				 

(* compare : parray_op * parray_op -> order *)
(* for use in ORD_KEY-based collections *)
  local
    fun consIndexPS (A.PSub_Nested _) = 0
      | consIndexPS (A.PSub_Flat _)   = 1
      | consIndexPS (A.PSub_Tuple _)  = 2
    fun consIndex (A.PA_Length _)        = 0
      | consIndex (A.PA_Sub _)           = 1
      | consIndex (A.PA_Tab _)           = 2
      | consIndex (A.PA_TabFTS _)        = 3
      | consIndex (A.PA_Map _)           = 4
      | consIndex (A.PA_Reduce _)        = 5
      | consIndex (A.PA_SegReduce _)     = 6
      | consIndex (A.PA_Range _)         = 7
      | consIndex (A.PA_App _)           = 8
      | consIndex (A.PA_TabTupleFTS _)   = 9
      | consIndex (A.PA_TabHD _)         = 10
      | consIndex (A.PA_PairMap _)       = 11
      | consIndex (A.PA_MapSP _)         = 12
  in

    val compare : A.parray_op * A.parray_op -> order = let

      fun $ cmp (xs, ys) = List.collate cmp (xs, ys)

      fun ps (o1, o2) = let
        val (i1, i2) = (consIndexPS o1, consIndexPS o2)
        in
          if (i1 <> i2) then Int.compare (i1, i2)
	  else case (o1, o2)
            of (A.PSub_Nested t1, A.PSub_Nested t2) => TU.compare (t1, t2)
	     | (A.PSub_Flat t1, A.PSub_Flat t2) => TU.compare (t1, t2)
	     | (A.PSub_Tuple os1, A.PSub_Tuple os2) => $ps (os1, os2)
	     | _ => raise Fail "compiler bug"
         end

      fun pop (o1, o2) = let
        val (i1, i2) = (consIndex o1, consIndex o2)
        in
          if (i1 <> i2) then Int.compare (i1, i2)
	  else case (o1, o2)
            of (A.PA_Length t1, A.PA_Length t2) => TU.compare (t1, t2)
	     | (A.PA_Sub s1, A.PA_Sub s2) => ps (s1, s2)
	     | (A.PA_Tab t1, A.PA_Tab t2) => TU.compare (t1, t2)
	     | (A.PA_TabFTS t1, A.PA_TabFTS t2) => TU.compare (t1, t2)
	     | (A.PA_TabTupleFTS ts1, A.PA_TabTupleFTS ts2) => $TU.compare (ts1, ts2)
	     | (A.PA_Map t1, A.PA_Map t2) => TU.compare (t1, t2)
	     | (A.PA_Reduce t1, A.PA_Reduce t2) => TU.compare (t1, t2)
	     | (A.PA_SegReduce t1, A.PA_SegReduce t2) => TU.compare (t1, t2)
	     | (A.PA_Range t1, A.PA_Range t2) => TU.compare (t1, t2)
	     | (A.PA_App t1, A.PA_App t2) => TU.compare (t1, t2)
	     | (A.PA_TabHD (d1, t1), A.PA_TabHD (d2, t2)) => (case Int.compare (d1, d2)
                 of EQUAL => TU.compare (t1, t2)
		  | neq => neq)
	     | (A.PA_PairMap t1, A.PA_PairMap t2) => TU.compare (t1, t2)
	     | (A.PA_MapSP t1, A.PA_MapSP t2) => TU.compare (t1, t2)
	     | _ => raise Fail "compiler bug"
        end
      in
        pop
      end

  end (* local *)

  val same : A.parray_op * A.parray_op -> bool = (fn ops => compare ops = EQUAL)

  structure OperKey : ORD_KEY = struct
    type ord_key = A.parray_op
    val compare = compare
  end

  structure Map = RedBlackMapFn(OperKey)

  structure Set = RedBlackSetFn(OperKey)

(* constructLength : ty -> exp *)
  fun constructLength t = A.PArrayOp (A.PA_Length t)

(* constructSub : ty -> exp *)
  val constructSub : T.ty -> A.exp = let
    fun mkPS (T.TupleTy ts) = A.PSub_Tuple (List.map mkPS ts)
      | mkPS (t as T.FArrayTy (_, s)) = (case s
          of T.LfTy => A.PSub_Flat t
	   | T.NdTy _ => A.PSub_Nested t
          (* end case *))
      | mkPS t = raise Fail ("constructSub(loc0): unexpected type " ^ TU.toString t)
    fun mk (t as T.TupleTy [t', i]) =
          if TU.same (B.intTy, i) then 
            A.PA_Sub (mkPS t')
	  else 
	    raise Fail ("constructSub(loc1): unexpected type " ^ TU.toString t)
      | mk t = raise Fail ("constructSub(loc2): unexpected type " ^ TU.toString t)
    in
      A.PArrayOp o mk
    end

(* constructTab : ty -> exp *)
  local
    val isInt = (fn t => TU.same (t, B.intTy))
    fun groundPairWitness (T.TupleTy [t1, t2]) = 
          if isGroundTy t1 andalso isGroundTy t2 then SOME (t1, t2) else NONE
      | groundPairWitness _ = NONE
    fun groundPair (g1, g2) = A.PArrayOp (A.PA_Tab (T.TupleTy [g1, g2]))
  in
    val constructTab : T.ty -> A.exp = let
      fun mk (domTy as T.TupleTy [i1, T.FunTy (i2, eltTy)]) =
            if not (isInt i1) orelse not (isInt i2) then
              raise Fail ("unexpected ty (ints expected) " ^ TU.toString domTy)
	    else (case groundPairWitness eltTy
              of SOME (g1, g2) => groundPair (g1, g2)
	       | NONE => let 
                   val eltsTy = T.FArrayTy (eltTy, T.LfTy)          
		   val fl = FlattenOp.construct eltTy
    		   val rngTy = TU.rangeType (FlattenOp.typeOf fl)
    		   val tab = A.PArrayOp (A.PA_Tab eltTy)
    		   val arg = Var.new ("arg", domTy)
		   (* note: in what follows, I cannot use ASTUtil.mkApplyExp *)
    		   (*   b/c referring to ASTUtil induces cyclic deps *)
    		   val body = A.ApplyExp (A.FlOp fl,
    					  A.ApplyExp (tab, A.VarExp (arg, []), eltsTy),
    					  rngTy)
                   in
                     A.FunExp (arg, body, rngTy)
                   end
              (* end case *))
	| mk t = raise Fail ("unexpected ty " ^ TU.toString t)
    in
      mk
    end
  end (* local *)

(* constructTabFTS : ty -> exp *)
  local
    val isInt = (fn t => TU.same (t, B.intTy))
    fun groundPairWitness (T.TupleTy [t1, t2]) = 
          if isGroundTy t1 andalso isGroundTy t2 then SOME (t1, t2) else NONE
      | groundPairWitness _ = NONE
    fun groundPair (g1, g2) = A.PArrayOp (A.PA_TabTupleFTS [g1, g2])
  in
    val constructTabFTS : T.ty -> A.exp = let
      fun mk (domTy as T.TupleTy [i1, i2, i3, T.FunTy (i4, eltTy)]) =
            if not (List.all isInt [i1, i2, i3, i4]) then
              raise Fail ("unexpected ty (ints expected) " ^ TU.toString domTy)
	    else (case groundPairWitness eltTy
              of SOME (g1, g2) => groundPair (g1, g2)
	       | NONE => let 
                   val eltsTy = T.FArrayTy (eltTy, T.LfTy)          
		   val fl = FlattenOp.construct eltTy
    		   val rngTy = TU.rangeType (FlattenOp.typeOf fl)
    		   val tab = A.PArrayOp (A.PA_TabFTS eltTy)
    		   val arg = Var.new ("arg", domTy)
		   (* note: in what follows, I cannot use ASTUtil.mkApplyExp *)
    		   (*   b/c referring to ASTUtil induces cyclic deps *)
    		   val body = A.ApplyExp (A.FlOp fl,
    					  A.ApplyExp (tab, A.VarExp (arg, []), eltsTy),
    					  rngTy)
                   in
		     A.FunExp (arg, body, rngTy)
                   end
              (* end case *))
	| mk t = raise Fail ("unexpected ty " ^ TU.toString t)
    in
      mk
    end
  end (* local *)

  fun isIntTy t = TU.same (B.intTy, t)
  fun isIntParrayTy t = TU.same (t, B.parrayTy B.intTy)

(*
  val constructTab2D : T.ty -> A.exp = let
    fun mk domTy = (case domTy
      of T.TupleTy [i1, i2, i3, i4, i5, i6, T.FunTy (T.TupleTy [i7, i8], resTy)] =>
           if not (List.all isIntTy [i1, i2, i3, i4, i5, i6, i7, i8]) then
             raise Fail ("unexpected ty (ints expected) " ^ TU.toString domTy)
	   else (case resTy
             of T.FArrayTy (eltTy, T.LfTy) => let
                  val tab = A.PA_Tab2D eltTy
                  in
	            A.PArrayOp tab
		  end
	      | t => raise Fail ("??:" ^ TU.toString resTy)
             (* end case *))
       | t => raise Fail ("unexpected ty " ^ TU.toString t)
      (* end case *))
    in
      mk
    end
*)

  val constructTabHD : T.ty -> A.exp = let
    fun mk domTy = (case domTy
      of T.TupleTy [] => raise Fail "unexpected ty: unit"
       | T.TupleTy ts => let
           val (last, butlast) = (case List.rev ts
             of x::xs => (x, List.rev xs)
              | [] => raise Fail "impossible")
	   val tripleTy = T.TupleTy [B.intTy, B.intTy, B.intTy]
	   fun isIntTriple t = TU.same (t, tripleTy)
	   val _ = if List.all isIntTriple butlast then ()
		   else raise Fail "non-int"
           in
	     case last
	      of T.FunTy (T.TupleTy ts', resTy) => let

		   val dim = List.length ts'
                   val _ = if dim = List.length(butlast) then ()
			   else let
		             val msg = "expected " ^ Int.toString dim ^
				       " int triples, got " ^ TU.toString domTy
			     in
		               raise Fail msg
			     end
		   fun lp (T.FArrayTy (t, _)) = lp t
		     | lp t = t
		   in
		     A.PArrayOp (A.PA_TabHD (dim, lp resTy))
		   end
	       | t => raise Fail ("unexpected ty: " ^ TU.toString t)
           end
       | t => raise Fail ("unexpected ty: " ^ TU.toString t)
      (* end case *))
    in
      mk
    end

(* constructMap : ty -> exp *)
  val constructMap : T.ty -> A.exp = let
    fun mk (ft as T.FunTy (domTy, rngTy)) = let
          val pr = fn ss => (print (String.concat ss); print "\n")
          (* val _ = pr ["called constructMap on ", TU.toString ft] *)
          val fl = FlattenOp.construct rngTy
	  (* val _ = pr ["fl is ", FlattenOp.toString fl] *)
	  val flRngTy = (case FlattenOp.typeOf fl
            of T.FunTy (_, r) => r
	     | t => raise Fail ("unexpected ty " ^ TU.toString t)
            (* end case *))
	  fun a t = T.FArrayTy (t, T.LfTy)
	  val f = Var.new ("f", ft)
	  val arr = Var.new ("arr", a domTy)
	  val mapOp = A.PArrayOp (A.PA_Map ft)
          (* note: in what follows, I cannot use ASTUtil.mkApplyExp *)
	  (*   b/c referring to ASTUtil induces cyclic deps *)
	  (* here I am building the following term: *)
          (*   fn f => fn arr => fl (map f arr) *)
	  val innerApp0 = A.ApplyExp (mapOp, A.VarExp (f, []), A.FunTy (a domTy, a rngTy))
	  val innerApp1 = A.ApplyExp (innerApp0, A.VarExp (arr, []), a rngTy)
	  val innerApp2 = A.ApplyExp (A.FlOp fl, innerApp1, flRngTy)
	  val innerFn = A.FunExp (arr, innerApp2, flRngTy)
	  val outerFn = A.FunExp (f, innerFn, T.FunTy (a domTy, flRngTy))
          in
            outerFn
          end
      | mk t = raise Fail ("unexpected ty " ^ TU.toString t) 
    in
      mk
    end

  val constructPairMap : T.ty -> A.exp = let
    fun mk (T.TupleTy [fTy as T.FunTy (domTy, rngTy), t1, t2]) = 
          A.PArrayOp (A.PA_PairMap fTy)
      | mk t = raise Fail ("unexpected ty " ^ TU.toString t)
    in
      mk
    end

(* constructReduce : ty -> exp *)
  val constructReduce : T.ty -> A.exp = let
    fun isGroundPair t = (case t
      of T.TupleTy [t1, t2] => isGroundTy t1 andalso isGroundTy t2
       | _ => false
      (* end case *))
    fun mk (operTy as T.FunTy (T.TupleTy [t1, t2], t3)) =
          if TU.same (t1, t2) andalso TU.same (t2, t3) then
            (if isGroundTy t1 orelse isGroundPair t1 then
               A.PArrayOp (A.PA_Reduce t1)
	     else
               raise Fail ("todo: reduce for type " ^ TU.toString t1))
	  else
            raise Fail ("cannot be an associative operator with type " ^ 
			TU.toString operTy)
      | mk t = raise Fail ("unexpected type " ^ TU.toString t)
    in
      mk
    end

(* constructSegReduce : ty -> exp *)
  val constructSegReduce : T.ty -> A.exp = let
    fun fail msg = raise Fail ("constructSegReduce: " ^ msg)
    fun parr c = TyCon.same (c, B.parrayTyc)
    fun mk (argsTy as T.TupleTy [operTy, identTy, parrTy]) = let
          (* make some assertions before proceeding *)
          (* check that oper is of type t*t->t *)
          val t = (case operTy
            of T.FunTy (T.TupleTy [t1, t2], t3) =>
	         if TU.same (t1, t2) andalso TU.same (t2, t3) then t1
		 else fail ("bogus operTy " ^ TU.toString operTy)
	     | _ => fail ("bogus operTy " ^ TU.toString operTy)
            (* end case *))
          (* check that ident is of the same type t *)
	  val _ = if TU.same (t, identTy) then () 
		  else fail ("bogus identTy: " ^ TU.toString identTy)
	  (* check that parr is of type t parray parray *)
	  val _ = (case parrTy
	    of T.FArrayTy (t', T.NdTy T.LfTy) =>
                 if TU.same (t, t') then ()
		 else fail ("bogus parrTy: " ^ TU.toString parrTy)
	     | _ => fail ("bogus parrTy: " ^ TU.toString parrTy)
            (* end case *))
          in
            A.PArrayOp (A.PA_SegReduce t)
          end
      | mk t = fail ("unexpected type " ^ TU.toString t)
    in
      mk
    end

(* constructMapSP : ty -> exp *)
  val constructMapSP : T.ty -> A.exp = let
    fun mk (argsTy as T.TupleTy [fty, T.TupleTy [arrTy1, arrTy2]]) = 
         (case fty
	   of T.FunTy (T.TupleTy [a1, a2], b) =>
                (case (arrTy1, arrTy2)
		  of (T.FArrayTy (eltTy1, T.NdTy T.LfTy), T.FArrayTy (eltTy2, T.NdTy T.LfTy)) =>
		       if TU.same (a1, eltTy1) andalso TU.same (a2, eltTy2) then
		         A.PArrayOp (A.PA_MapSP fty)
		       else
                         raise Fail ("bad types(1): " ^ TU.toString argsTy)
		   | _ => raise Fail ("bad types(2): " ^ TU.toString argsTy)
                  (* end case *))
	    | _ => raise Fail ("bad types(3): " ^ TU.toString argsTy)
	   (* end case *))
      | mk argsTy = raise Fail ("bad types(4): " ^ TU.toString argsTy)
    in
      mk
    end

(* constructRange : ty -> exp *)
  val constructRange : T.ty -> A.exp = let
    fun mk (t as T.TupleTy (ts as [t1, t2, t3])) = 
          if List.all (fn t => TU.same (t, B.intTy)) ts then
	    A.PArrayOp (A.PA_Range B.intTy)
	  else            
            raise Fail ("unexpected type " ^ TU.toString t)
      | mk t = raise Fail ("unexpected type " ^ TU.toString t)
    in
      mk
    end

(* have to copy some of ASTUtil here; cyclic deps :-( *)
  fun mkIntLit n = Literal.Int (IntInf.fromInt n)
  fun mkIntConst n = A.LConst (mkIntLit n, Basis.intTy)
  fun mkIntPat n = A.ConstPat (mkIntConst n)
  fun mkInt n = A.ConstExp (mkIntConst n)

  fun plusOne n = A.ApplyExp (A.VarExp (B.int_plus, []),
			      A.TupleExp [n, mkInt 1],
			      B.intTy)

  fun mkApply resTy = let
    fun app (e, []) = raise Fail "mkApply.app"
      | app (e, [x]) = A.ApplyExp (e, x, resTy)
      | app (e, xs) = A.ApplyExp (e, A.TupleExp xs, resTy)
    in
      app
    end
			
  val intApp = mkApply B.intTy
  val boolApp = mkApply B.boolTy
  val unitApp = mkApply B.unitTy

(* constructApp : ty -> exp *)
(* At the moment, the supported types are ground types, parrays of ground types, *)
(*   and tuples of supported types. *)
(* I don't yet do datatypes. The problem is I need to do some type flattening here *)
(*   and I'm not ready to flatten datatypes here in ast/. It's doable, but I'm leaving it *)
(*   to the future for now. *)
  local
    val supportedTy : T.ty -> bool = let
      fun s t = 
        if isGroundTy t then 
          true
	else (case t
	  of T.FArrayTy (t', _) => isGroundTy t'
	   | T.TupleTy ts => List.all s ts
	   | _ => false
	  (* end case *))
      in
	s
      end
  (* a function to "lift" supported types to parrays in a particular way -- *)
  (* - ground types are lifted to flat arrays of those types *)
  (* - arrays of ground types are lifted one level of depth *)
  (* - tuples of supported types are lifted to tuples of lifted types *)
  (* ex: int --> FArray (inf, Lf)                              *)
  (* ex: FArray (int, Lf) --> FArray (int, Nd Lf)              *)
  (* ex: (int * int) --> (FArray (int, Lf) * FArray (int, Lf)) *)
  (*   (as opposed to FArray (int * int, Lf))                  *)
    val lift : T.ty -> T.ty = let
      fun l t =
        if isGroundTy t then
          T.FArrayTy (t, T.LfTy)
	else (case t
          of T.FArrayTy (t', n) => T.FArrayTy (t', T.NdTy n)
	   | T.TupleTy ts => T.TupleTy (List.map l ts)
	   | _ => raise Fail ("lift: unexpected type " ^ TU.toString t)
          (* end case *))
      in
	l
      end
  in
  (* constructApp : ty -> exp *)
  (* For each use of app, this code will synthesize a monomorphic function as follows:
       let fun app (f : t -> unit) = let
         fun f' arr = let
           val n = PArray.length arr
           fun lp i = if (i >= n) then ()
	              else (f (arr!i)); lp (i+1))
           in lp 0 end
         in f' end
      in app end 
    for some monomorphic type t and specialized PArray.length and !.
  *)
  (* TODO don't generate this --every-- time it's needed... *)
    val constructApp : T.ty -> A.exp = let 
      fun mk (t as T.FunTy (eltTy, uTy)) =
            if not (TU.same (B.unitTy, uTy)) then 
              raise Fail ("unexpected type " ^ TU.toString t)
            else if not (supportedTy eltTy) then
              raise Fail ("constructApp: unsupported type " ^ TU.toString t)
	    else (* generate custom app function *) let
             (* val _ = print ("*** generating custom app for elt ty " ^ TU.toString eltTy ^ "\n") *)
	      fun v x = A.VarExp (x, [])
	      val eltTy' = lift eltTy
              val lenExp = constructLength eltTy'
	      val subExp = constructSub (T.TupleTy [eltTy', B.intTy])
	      val app = Var.new ("app", (eltTy --> B.unitTy) --> (eltTy' --> B.unitTy))
	      val f = Var.new ("f", eltTy --> B.unitTy)
	      val f' = Var.new ("f'", eltTy' --> B.unitTy)
	      val arr = Var.new ("arr", eltTy')
	      val n = Var.new ("n", B.intTy)
	      val lp = Var.new ("lp", B.intTy --> B.unitTy)
	      val i = Var.new ("i", B.intTy)
	      val subi = mkApply eltTy (subExp, [v arr, v i])
	      val seq = A.SeqExp (unitApp (v f, [subi]), intApp (v lp, [plusOne (v i)]))
	      val lpTest = boolApp (v B.int_gte, [v i, v n])
              val lpBody = A.IfExp (lpTest, A.TupleExp [], seq, B.unitTy)		
	      val lpLam = A.FB (lp, i, lpBody)
	      val lpBind = A.FunBind [lpLam]
	      val nBind = A.ValBind (A.VarPat n, intApp (lenExp, [v arr]))
	      val f'Body = A.LetExp (nBind, A.LetExp (lpBind, unitApp (v lp, [mkInt 0])))
	      val f'Lam = A.FB (f', arr, f'Body)
	      val appBody = A.LetExp (A.FunBind [f'Lam], v f')
	      val appLam = A.FB (app, f, appBody)
	      in
                A.LetExp (A.FunBind [appLam], v app)
	      end
	| mk t = raise Fail ("constructApp: unexpected type " ^ TU.toString t)
      in
        mk
      end
  end (* local *)
        
end