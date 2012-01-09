(* ast-cost.sml
*
* COPYRIGHT (c) 2006 The Manticore Project (http://manticore.cs.uchicago.edu)
* All rights reserved.
*)

structure ASTCost : sig

        val translate : AST.exp -> AST.exp
        val costAST : AST.var * AST.exp -> int

end = struct


    structure A = AST
    structure B = Basis
    structure V = Var
    structure Ty = Types
    structure U = ASTUtil


    infixr 2 -->
    fun t1 --> t2 = Ty.FunTy (t1, t2)

    fun vexp v = AST.VarExp (v, [])

    fun dummyvar () = (Var.new ("dummy", B.unitTy))
    
    (* unkown costs is -1 *)
    val Cunkown = ~1

    (* cut off limit for the costs *)
    val Tlimit = 1000


    (* f is the variable we want to assign a value to *)
    local
        val {setFn, getFn, peekFn, clrFn} = V.newProp (fn f => ~1)
    in
        fun clearCost f = clrFn f
        fun setCost (f, cost) = setFn (f, cost)
        fun getCost f = getFn f
        (* returns SOME var if exist otherwise NONE *) 
        fun exist f = peekFn f
    end  

    (* f is the variable we want to assign a value to *)
    (* we use this to store the extra information to create the cost function, especially the fixcosts *)
    local
        val {setFn, getFn, peekFn, clrFn} = V.newProp (fn f => ~1)
    in
        fun clearCostfct f = clrFn f
        fun setCostfct (f, cost) = setFn (f, cost)
        fun getCostfct f = getFn f
        (* returns SOME var if exist otherwise NONE *) 
        fun existCostfct f = peekFn f
    end  

    (* prune out overload nodes.
   * NOTE: we should probably have a pass that does this before
   * AST optimization.
   *)
    fun prune (AST.OverloadExp(ref(AST.Instance x))) = AST.VarExp(x, [])
      | prune (AST.OverloadExp _) = raise Fail "unresolved overloading"
      | prune e = e

(*
-----------------------------------------------------------------------------------------------
This function analyzes the tree and assigns costs to functions or ~1 if we need to reevaluate and maybe create a cost function
-----------------------------------------------------------------------------------------------
*)

    (* function to assign cost values to AST expressions if possible if the function is open it assigns ~1 *)
    fun costAST (pre,exp) = (case prune exp 
            of e as AST.LetExp(_,_) => let
                        fun costBinds (A.LetExp(b, e)) = let
                                val c1 = cost_binding(b,pre)
                                val c2 = costBinds(e)
                                val c = c1 + c2
                           in   
                                c
                           end
                           | costBinds e = costAST(pre,e)
        
                        val _ = TextIO.print("LetExp normal \n")
                        val c = costBinds(e)
                in      
                        TextIO.print(String.concat["Cost are " , Int.toString c, "end Let\n"]);
                        c
                end
	    | AST.IfExp(e1, e2, e3, ty) => let
                        val _ = TextIO.print("IfExp of type\n") 
                        val _ = TextIO.print(TypeUtil.toString ty)
                        val c1 = costAST(pre,e1)
                        val c2 = costAST(pre,e2)
                        val c3 = costAST(pre,e3)
                        val c = 1 + c1 + Int.max(c2,c3)
                        val _ = TextIO.print(String.concat[" If exp Cost are " , Int.toString c, " (** end IF **) "])
                in      
                        c
                end
	    | AST.CaseExp(e, rules, ty) => let
                        val _ = TextIO.print("CaseExp of type\n")
                        val c1 = costAST(pre,e)
                        val c2 = casematch(rules, pre)
                        val c = c1 + c2
                        val _ = TextIO.print(String.concat["cost are ",Int.toString c, " * (end case) * \n"])
                in     
                        c
                end
            (* FIX ME need function costs *)
            | AST.FunExp(x, body, ty) => let
                        val _ = TextIO.print("FunExp of type \n")
                        (* val _ = mysize(ty) *)
                        val _ = TextIO.print(TypeUtil.toString ty)
                        val _ = TextIO.print (V.toString x)
                        val c1 = costAST(x,body)
                        val c = c1
                        fun varcost () = (
                                case exist x
                                of (SOME num) => setCostfct(x,c)
                                | NONE =>  setCost (x, c)
                        )
                        val _ = TextIO.print(String.concat["Cost are", Int.toString c, "\n"])  
                in      
                        c
                end
            (* FIX ME add cost of eval function *)
            | AST.ApplyExp(e1, e2, ty) => let
                        val _ = TextIO.print("ApplyExp of type (")
                        val _ = TextIO.print(TypeUtil.toString ty)
                        val _ = TextIO.print("\n")
                        val c1 = costAST(pre,e1)
                        val c2 = costAST(pre,e2)
                        val c = c1 + c2 + 1
                        val _ =  TextIO.print(String.concat["Apply costs are ", Int.toString c, ") \n ** end apply ** \n"])
                in
                        c 
                end
            | AST.TupleExp[] => 0
            | AST.TupleExp (exps) => let
(* FIX ME : need to check for not closed expressions *)
                        val _ = TextIO.print("TupleExp not unit \n")
                        val exps' = List.map (fn e => costAST(pre, e)) exps
                        fun addL(L) =
                                if L=[] 
                                then 0 
                                else hd(L) + addL(tl(L))
                        val c = addL(exps')
                        val _ = TextIO.print(String.concat["TupleExp costs are ", Int.toString c, "\n (** End Tupleexp **) \n"])
                in           
                        c
                end
            (* FIX ME VAR EXP *)
            | AST.VarExp(x, tys) => let
                                fun varcost () = (
                                        case exist x
                                        of (SOME num) => num
                                        | NONE => let 
                                                val AST.TyScheme(_, tys) = V.typeOf x
                                                in
                                                        mysize(tys)
                                                end
                                        )
                                val mycost = varcost()

                                (* we check for recursive and unknown function here *)
                                val _ = if (mycost = ~1) then setCost(pre,~1) 
                                                      else TextIO.print(String.concat["Var exp ", printvar(x), "is fine \n"])
                        in
                                TextIO.print(String.concat["Var exp ", printvar(x), " with costs for size ", Int.toString mycost, " \n"]);
                                mycost
                        end
            | AST.PCaseExp _ => raise Fail "PCaseExp" (* FIXME *)
	    | AST.HandleExp(e, mc, ty) =>  let
                        val _ = TextIO.print("HandleExp\n")
                in           
                        0
                end
		       
	    | AST.RaiseExp(e, ty) => let
                        val _ = TextIO.print("RaiseExp\n")
                in           
                        0
                end
	    | AST.VarArityOpExp (oper, i, ty) => 0
	    | AST.RangeExp (lo, hi, optStep, ty) => raise Fail "FIXME (range construction)"
            | AST.PTupleExp[] => 0
            | AST.PTupleExp (exps) => let
                        val _ = TextIO.print("PTupleExp\n")
                      (*  val c1 = costAST(pre,e) *)
                        (* We need the maximum of all the ptuple expressions *)
(* FIX ME : need to check for not closed expressions *)
                        fun maxList(L) = 
                                if L=[] 
                                then ~1 
                                else Int.max(hd(L), maxList(tl(L)))
                        val exps' = List.map (fn e => costAST(pre, e)) exps
                        val c = maxList(exps');
                        val _ = TextIO.print(String.concat["PTupleExp costs are ", Int.toString c, "\n (** End PTupleexp **) \n"])
                in                          
                        c
                end
	    | AST.PArrayExp(exps, ty) => raise Fail "unexpected PArrayExp"
	    | AST.PCompExp _ => raise Fail "unexpected PCompExp"
	    | AST.PChoiceExp _ => raise Fail "unexpected PChoiceExp"
	    | AST.SpawnExp e => let
                        val _ = TextIO.print("SpawnExp\n")
                in           
                        costAST(pre,e)
                end
	    | AST.ConstExp (constexp) => const_cost(constexp)
	    | AST.SeqExp (e1,e2) => let
                        val _ = TextIO.print("SeqExp\n")
                        val c1 = costAST(pre,e1)
                        val c2 = costAST(pre,e2)
                in           
                        c1 + c2
                end
	    | AST.OverloadExp _ => raise Fail "unresolved overloading"
	    | AST.ExpansionOptsExp (opts, e) => let
                        val _ = TextIO.print("ExpansionoptsExp\n")
                in           
                        costAST(pre,e)
                end
        )

        and const_cost(conexpr) = (case conexpr
                of AST.DConst(_,tylist) => let 
                                        val _ = TextIO.print("DConst exp \n")
                                in
                                        length(tylist)
                                end
                | AST.LConst (_) => let 
                                        val _ = TextIO.print("LConst exp \n")
                                in
                                        0
                                end
        )

        and cost_binding (e,pre) = (case e
                        of AST.ValBind(p, e) => let
                                                val _ = TextIO.print("val XX = \n")
                                        in
                                                costAST(pre,e)
                                        end
                        | AST.PValBind(p, e) => let
                                                val _ = TextIO.print("pval XX =")
                                        in
                                                costAST(pre,e)
                                        end
                        | AST.FunBind(lam) => let
                                        val _ = TextIO.print("FunExp in LetExp \n")
                                        val c = costlambda(lam,pre)
                                        val _ = TextIO.print(String.concat["with cost  ", Int.toString c, "\n"])
                                in
                                        c
                                end
                        (* these should be the primitive operators *)
                        (* | AST.PrimVBind (x, _) => mysize(V.typeof x) *)
                        | AST.PrimVBind (x, _) => let 
                                        val _ = TextIO.print(String.concat["Primbinding ",printvar(x), " with cost 1 \n"])
                                        val _ = setCost(x,1)
                                in
                                        1
                                end
                        | AST.PrimCodeBind _ => let 
                                        val _ = TextIO.print("AST.PrimCodeBind with cost 0 \n")
                                in
                                        0
                                end
                        
        )
        (* for the case e of pat => expr take the maximum of the (pat,expr) pair *)
        and casematch (rule::rest, pre) = (case rule 
                                of AST.PatMatch (pat,e) => let
                                        val _ = TextIO.print("PatMatch \n")
                                        val c = costAST(pre,e)
                                in      
                                        Int.max(c,casematch(rest, pre))
                                end
                                (* CondMatch is not used yet *)
                                | AST.CondMatch (pat,e1,e2) => 0
                                )
                        | casematch ([], _) = 0
        (* FIX ME *)
        and costlambda ([], _) = 0
                | costlambda ( A.FB(f, x, e)::l, pre ) = let
                        (* look up cost of the function *)
                        val _ = TextIO.print(String.concat["Funbinding ", printvar(f), " to " , printvar(x)," \n"])
                        val c = costAST(f,e)
                        (* check if the costs are -1 already which means unknown *)
                        fun varcost () = (
                                case exist f
                                of (SOME num) => setCostfct(f,c)
                                | NONE =>  setCost (f, c)
                        )
                        val _ = TextIO.print(String.concat["Funbinding ", printvar(f), " has cost ", Int.toString c," \n (** End Funbinding **) \n"])
                        val readout = getCost(f)
                        val _ = TextIO.print(String.concat["Check: Reading out the cost of the function = ", Int.toString readout, " !!******!!! "])
                in
                        costlambda(l,pre)
                end

        (* MISSING and pmatch *)

        (* we shouldn't need this
        and cost_pat (expr,pre) = (case expr 
                of AST.ConPat (dcon,_,pat) => TextIO.print ("Conpat\n")
                | AST.TuplePat(p::pat) => TextIO.print ("TuplePat\n")
                | AST.VarPat(v) => TextIO.print ("VarPat\n")
                | AST.WildPat(ty) => TextIO.print ("WildPat\n")
                | AST.ConstPat(con) => TextIO.print ("ConstPat\n")
        )
        *)

        (* Types.ty -> cost *)
        (* type const should just contain basic types like numbers and string/chars *)
        and mysize (ty1) = let
	  fun toS(Ty.ErrorTy) = 0
	    | toS (Ty.MetaTy mv) =  0
	    | toS (Ty.VarTy tv) = 0 (* FIX ME type variable *)
	    | toS (Ty.ConTy([], tyc)) = 0
	    | toS (Ty.ConTy([ty], tyc)) = 1
	    | toS (Ty.ConTy(tys, tyc)) = length(tys)
	   (* | toS (Ty.FunTy(ty1 as Ty.FunTy _, ty2)) = TextIO.print ("funType 1\n") *)
	    | toS (Ty.FunTy(ty1, ty2)) = ~1 (* SHOULD BE THE RECURSIVE FUNCTION *)
	    | toS (Ty.TupleTy []) = 0
	    | toS (Ty.TupleTy tys) = length(tys)
	  in
	    toS(ty1)
	  end

        and printvar(x) = String.concat[Var.toString x, " : ", TypeUtil.schemeToString (Var.typeOf x),"\n"]



(* FIX ME: just takes fix costs and the number of recursive calls to itself and the function name so far *)
        and create_cost_fct (cost, numrec, f, x) = let
                (* create the name of the function and the type of the input argument *)
                val costname = String.concat[Var.toString f, "cost"]
                val AST.TyScheme(_, argtys) = V.typeOf x
                val estCost = Var.new (costname,argtys --> B.intTy) (* compute the appropriate function type *)
                (* create the input argument for the cost function *)
                val inputname = String.concat[Var.toString f, "arg"]
                val inputCostFn = Var.new (inputname, argtys)
                (* create the recursive function call to the cost function *)
                val body = (U.plus (U.mkInt(cost)) (U.times (U.mkInt(numrec)) (U.mkApplyExp(vexp estCost,[vexp inputCostFn]))) )
                val estCostFn = U.mkFunWithParams(estCost,[inputCostFn], body)
                in
                        estCostFn
                end

(*
-----------------------------------------------------------------------------------------------
This function will create cost functions for the open function costs of the previous analysis or add unknown
to the function if we can't assign costs to it
-----------------------------------------------------------------------------------------------
*)

        fun costFctsAST (exp) = (case prune exp 
                of e as AST.LetExp(_,_) => let
                        fun letBinds (AST.LetExp(b, e)) = let
                                val b1 = binding(b)
                                val c1 = letBinds(e)
                           in   
                                ()
                           end
                           | letBinds e = costFctsAST(e)
                in      
                        letBinds(e)
                end
	    | AST.IfExp(e1, e2, e3, ty) => let
                        val _ = costFctsAST(e1)
                        val _ = costFctsAST(e2)
                        val _ = costFctsAST(e3)
                        in
                                ()
                        end
	    | AST.CaseExp(e, rules, ty) => let
                        val _ = costFctsAST(e)
                        in
                                casematch(rules)
                        end
            | AST.FunExp(x, body, ty) => (
                        case exist x
                                of (SOME num) => ()
                                | NONE =>  let
(* FIX ME NEED TO RECOMPUTE COSTS HERE *)
                                        val cost = 0
                                        in
                                                case cost
                                                of ~1 => setCost (x, Cunkown)
                                                | Cunkown => setCost (x, Cunkown)
                                                (* | _ => setCost (x, cost) *)
                                        end
                )
            | AST.ApplyExp(e1, e2, ty) => let
                                val _ = costFctsAST(e1)
                        in
                                costFctsAST(e2)
                        end
            | AST.TupleExp[] => ()
            | AST.TupleExp (exps) => let
                                val _ = List.map (fn e => costFctsAST(e)) exps
                        in
                                ()
                        end
            | AST.VarExp(x, tys) => (case getCost x
                        of ~1 => TextIO.print(String.concat["Variable ", printvar(x), " has cost ", Int.toString ~1," \n (** End VAR **) \n"])
                        | _ => TextIO.print(String.concat["Variable ", printvar(x), " has cost ", Int.toString (getCost x)," \n (** End VAR **) \n"])
                )
            | AST.PCaseExp _ => raise Fail "PCaseExp" (* FIXME *)
	    | AST.HandleExp(e, mc, ty) =>  ()   
	    | AST.RaiseExp(e, ty) => ()
	    | AST.VarArityOpExp (oper, i, ty) => ()
	    | AST.RangeExp (lo, hi, optStep, ty) => raise Fail "FIXME (range construction)"
            | AST.PTupleExp[] => ()
(* we have to change ptuple expressions to the if else statement *)
            | AST.PTupleExp (exps) => raise Fail "MISSING PTUPLE"
	    | AST.PArrayExp(exps, ty) => raise Fail "unexpected PArrayExp"
	    | AST.PCompExp _ => raise Fail "unexpected PCompExp"
	    | AST.PChoiceExp _ => raise Fail "unexpected PChoiceExp"
	    | AST.SpawnExp e => costFctsAST(e)
	    | AST.ConstExp (constexp) => ()
	    | AST.SeqExp (e1,e2) => let
                                val _ = costFctsAST(e1) 
                        in
                                costFctsAST(e2)
                        end
	    | AST.OverloadExp _ => raise Fail "unresolved overloading"
	    | AST.ExpansionOptsExp (opts, e) => costFctsAST(e)
        )

        and binding (e) = (case e
                        of AST.ValBind(p, e) => costFctsAST(e)
                        | AST.PValBind(p, e) => costFctsAST(e)
                        | AST.FunBind(lam) => lambda(lam)
                        (* these should be the primitive operators *)
                        (* | AST.PrimVBind (x, _) => mysize(V.typeof x) *)
                        | e => ()
                        
        )
        (* for the case e of pat => expr take the maximum of the (pat,expr) pair *)
        and casematch (rule::rest) = (case rule 
                                of AST.PatMatch (pat,e) => let
                                        val _ = costFctsAST(e)
                                in      
                                        casematch(rest)
                                end
                                (* CondMatch is not used yet *)
                                | AST.CondMatch (pat,cond,e2) => raise Fail "unexpected AST.CondMatch"
                                )
                        | casematch ([]) = ()
        (* FIX ME *)
        and lambda ([]) = () 
                | lambda ( A.FB(f, x, e)::l ) = (case getCost(f) 
                                of ~1 => let
                                                val _ = TextIO.print("Need to add costs here\n")
                                        in
                                                lambda(l)
                                        end
                                | _ => lambda(l)
                )
(* fix me add check for function *)


(*
-----------------------------------------------------------------------------------------------
This function will add a sequential version and changes the original PTuple expression for chunking
PtupleExp(exp) => If(Cost > Threshhold) then Ptupleexp else Tupleexp
-----------------------------------------------------------------------------------------------
*)

        fun ASTaddchunking (exp) = (case prune exp 
                of e as AST.LetExp(_,_) => let
                        fun letBinds (AST.LetExp(b, e)) = let
                                val b1 = binding(b)
                                val c1 = letBinds(e)
                           in   
                                AST.LetExp(b1, c1)
                           end
                           | letBinds e = ASTaddchunking(e)
                in      
                        letBinds(e)
                end
	    | AST.IfExp(e1, e2, e3, ty) => AST.IfExp(ASTaddchunking(e1), ASTaddchunking(e2), ASTaddchunking(e3), ty)
	    | AST.CaseExp(e, rules, ty) => AST.CaseExp(ASTaddchunking(e) , casematch(rules), ty)
            | AST.FunExp(x, body, ty) => AST.FunExp(x, ASTaddchunking(body), ty)
            | AST.ApplyExp(e1, e2, ty) => AST.ApplyExp(ASTaddchunking(e1), ASTaddchunking(e2), ty)
            | AST.TupleExp[] => AST.TupleExp[]
            | AST.TupleExp (exps) => let
                        val exps' = List.map (fn e => ASTaddchunking( e)) exps
                in           
                        AST.TupleExp (exps')
                end
            | AST.VarExp(x, tys) => AST.VarExp(x, tys)
            | AST.PCaseExp _ => raise Fail "PCaseExp" (* FIXME *)
	    | AST.HandleExp(e, mc, ty) =>  AST.HandleExp(e, mc, ty)   
	    | AST.RaiseExp(e, ty) => AST.RaiseExp(e, ty)
	    | AST.VarArityOpExp (oper, i, ty) => AST.VarArityOpExp (oper, i, ty)
	    | AST.RangeExp (lo, hi, optStep, ty) => raise Fail "FIXME (range construction)"
            | AST.PTupleExp[] => AST.PTupleExp[]
(* we have to change ptuple expressions to the if else statement *)
            | AST.PTupleExp (exps) => ptup (exps)
	    | AST.PArrayExp(exps, ty) => raise Fail "unexpected PArrayExp"
	    | AST.PCompExp _ => raise Fail "unexpected PCompExp"
	    | AST.PChoiceExp _ => raise Fail "unexpected PChoiceExp"
	    | AST.SpawnExp e => AST.SpawnExp(ASTaddchunking(e))
	    | AST.ConstExp (constexp) => AST.ConstExp (constexp)
	    | AST.SeqExp (e1,e2) => AST.SeqExp (ASTaddchunking(e1),ASTaddchunking(e2))
	    | AST.OverloadExp _ => raise Fail "unresolved overloading"
	    | AST.ExpansionOptsExp (opts, e) => AST.ExpansionOptsExp (opts, ASTaddchunking(e)) 
        )

        and binding (e) = (case e
                        of AST.ValBind(p, e) => AST.ValBind(p,ASTaddchunking(e))
                        | AST.PValBind(p, e) => AST.PValBind(p,ASTaddchunking(e))
                        | AST.FunBind(lam) => AST.FunBind(lambda(lam))
                        (* these should be the primitive operators *)
                        (* | AST.PrimVBind (x, _) => mysize(V.typeof x) *)
                        | e => e
                        
        )
        (* for the case e of pat => expr take the maximum of the (pat,expr) pair *)
        and casematch (rule::rest) = (case rule 
                                of AST.PatMatch (pat,e) => let
                                        val e1 = ASTaddchunking(e)
                                in      
                                        AST.PatMatch(pat,e1)::casematch(rest)
                                end
                                (* CondMatch is not used yet *)
                                | AST.CondMatch (pat,cond,e2) => raise Fail "unexpected AST.CondMatch"
                                )
                        | casematch ([]) = [] 
        (* FIX ME *)
        and lambda ([]) = [] 
                | lambda ( A.FB(f, x, e)::l) = let
                        val e1 = ASTaddchunking(e)
                in
                        A.FB(f, x, e1)::lambda(l)
                end


        and ptup (exps) = 
         (case exps
           of [e1, e2] => let
                val exps' = List.map (fn e => ASTaddchunking( e)) exps
                (* The ptuple statement (| exp1, exp2 |) will change to if (cost(exp1) + cost(exp2) > T) then (| exp1, exp2 |) else ( exp1, exp2 ) *) 
                (* where cost() a function that may have to compute the cost on the fly *)

                (* replace this by the actual costs of the statement *)
                val estCost1 = Var.new ("estCost1", B.unitTy --> B.intTy) (* compute the appropriate function type *)
                val estCostFn1 = U.mkFunWithParams(estCost1,[], U.mkInt 5)
                val estCost2 = Var.new ("estCost2", B.unitTy --> B.intTy)
                val estCostFn2 = U.mkFunWithParams(estCost2, [], U.mkInt 6)
                val estCost = Var.new ("estCost", Basis.intTy)
                (* creates a fun ... and ... *)
                val bindEstCosts = AST.FunBind [estCostFn1, estCostFn2]
                val bindEstCost = AST.ValBind(AST.VarPat estCost, 
                                              U.mkMax(U.mkApplyExp(vexp estCost1, [U.unitExp]),
                                                      U.mkApplyExp(vexp estCost2, [U.unitExp])))
                val threshold = U.mkInt(Tlimit)
                val test = U.intGT(vexp estCost, threshold)
                in           
                  U.mkLetExp([bindEstCosts,bindEstCost], U.mkIfExp(test,AST.PTupleExp(exps'),AST.TupleExp(exps')))
                end
            | _ => raise Fail "only pair ptups currently supported in this branch"
          (* end case *))


        fun translate (body) = let
                val _ = costAST(dummyvar() , body)
                val _ = costFctsAST(body)
                val body' = ASTaddchunking(body)
        in   
                body'
        end

end