(* direct-flat-closure.sml
 *
 * COPYRIGHT (c) 2016 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * This is a simple closure conversion algorithm.  In general, function
 * closures are represented as an environment-pointer (EP) / code-pointer (CP)
 * pair.  Mutually recursive functions share the same environment and use direct
 * calls to each other.  Continuation closures are represented as a record with
 * the first word containing the code pointer.
 *)

structure DirectFlatClosureWithCFA : sig

    val convert : CPS.module -> CFG.module

  end = struct

    structure CFA = CFACPS
    structure FV = FreeVars
    structure VMap = CPS.Var.Map
    structure ST = Stats
    structure CC = ClassifyConts
    
    (********** Counters for statistics **********)
    val cntJoinContOpt    = ST.newCounter "clos:optimize-joink"

  (* return the variable of a lambda *)
    fun funVar (CPS.FB{f, ...}) = f

  (* convert from CPS types to CFG types, guided by CFA values; *)
  (* BOT values can arise in CFA from dead code. *)
    fun cvtTy (CPSTy.T_Any, _) = CFG.T_Any
      | cvtTy (CPSTy.T_Enum w, CFA.TOP) = CFG.T_Enum w
      | cvtTy (CPSTy.T_Enum w, CFA.BOT) = CFG.T_Enum w
      | cvtTy (CPSTy.T_Enum w, CFA.BOOL _) = CFG.T_Enum w
      | cvtTy (CPSTy.T_Raw rTy, CFA.TOP) = CFGTy.T_Raw rTy
      | cvtTy (CPSTy.T_Raw rTy, CFA.TUPLE _) = CFGTy.T_Raw rTy (* datatypes *)
      | cvtTy (CPSTy.T_Raw rTy, CFA.BOT) = CFGTy.T_Raw rTy
      | cvtTy (CPSTy.T_Tuple(mut, tys), CFA.TOP) = 
          CFG.T_Tuple(mut, List.map cvtTyTop tys)
      | cvtTy (CPSTy.T_Tuple(mut, tys), CFA.TUPLE vs) = let
          val tysLen = List.length tys
          val vsLen = List.length vs
          val vs' = if tysLen <= vsLen
                       then List.take (vs, tysLen)
                    else vs @ (List.tabulate (tysLen - vsLen, fn _ => CFA.TOP))
          in
            CFG.T_Tuple(mut, ListPair.map cvtTy (tys, vs'))
          end
      | cvtTy (CPSTy.T_Tuple(mut, tys), CFA.BOT) = 
          CFG.T_Tuple(mut, List.map cvtTyBot tys)
      | cvtTy (CPSTy.T_Addr ty, CFA.TOP) = CFG.T_Addr(cvtTyTop ty)
      | cvtTy (CPSTy.T_Addr ty, CFA.BOT) = CFG.T_Addr(cvtTyBot ty)
      | cvtTy (ty as CPSTy.T_Cont _, v) = cvtStdContTy (ty, v)
      | cvtTy (ty as CPSTy.T_Fun _, v) = cvtStdFunTy (ty, v)
      | cvtTy (CPSTy.T_CFun cproto, _) = CFGTy.T_CFun cproto
      | cvtTy (CPSTy.T_VProc, CFA.TOP) = CFGTy.T_VProc
      | cvtTy (CPSTy.T_VProc, CFA.BOT) = CFGTy.T_VProc
      | cvtTy (CPSTy.T_Deque, CFA.TOP) = CFGTy.T_Deque
      | cvtTy (CPSTy.T_Deque, CFA.BOT) = CFGTy.T_Deque
      | cvtTy (ty, v) = raise Fail(concat[
           "bogus type ", CPSTyUtil.toString ty, " : ", CFA.valueToString v])
    and cvtTyTop ty = cvtTy (ty, CFA.TOP)
    and cvtTyBot ty = cvtTy (ty, CFA.BOT)

  (* convert a function type to a standard-function type, guided by CFA values *)
    and cvtStdFunTy (ty, v) = CFG.T_Tuple(false, [CFG.T_Any, cvtStdFunTyAux (ty, v)])
    and cvtStdFunTyAux (ty, CFA.TOP) = cvtStdFunTyAuxStd ty
      | cvtStdFunTyAux (ty, CFA.BOT) = cvtStdFunTyAuxStd ty
      | cvtStdFunTyAux (ty, v as CFA.LAMBDAS fs) = let
          val SOME f = CPS.Var.Set.find (fn _ => true) fs
          val CPS.VK_Fun (CPS.FB {params, rets, ...}) = CPS.Var.kindOf f
          in
             if CFA.isEscaping f
                then cvtStdFunTyAuxStd ty
             else cvtStdFunTyAuxKwn (ty, (params, rets))
          end
      | cvtStdFunTyAux (ty, v) = raise Fail(concat[
          "bogus function type ", CPSTyUtil.toString ty, " : ", CFA.valueToString v])
    and cvtStdFunTyAuxStd (CPSTy.T_Fun(argTys, [retTy, exhTy])) = CFGTy.T_StdFun{
            clos = CFGTy.T_Any,
            args = List.map cvtTyTop argTys,
            ret = cvtStdContTy (retTy, CFA.TOP),
            exh = cvtStdContTy (exhTy, CFA.TOP)
          }
      | cvtStdFunTyAuxStd (CPSTy.T_Fun(argTys, [retTy])) = CFGTy.T_KnownFunc{
            clos = CFGTy.T_Any,
            args = List.map cvtTyTop argTys @ [cvtStdContTy (retTy, CFA.TOP)]
          }
      | cvtStdFunTyAuxStd (CPSTy.T_Fun(argTys, [])) = CFGTy.T_KnownFunc{
            clos = CFGTy.T_Any,
            args = List.map cvtTyTop argTys
          }
      | cvtStdFunTyAuxStd (CPSTy.T_Any) = CFGTy.T_StdFun{
            clos = CFGTy.T_Any,
            args = [CFGTy.T_Any],
            ret = cvtStdContTy (CPSTy.T_Any, CFA.TOP),
            exh = cvtStdContTy (CPSTy.T_Any, CFA.TOP)
          }
      | cvtStdFunTyAuxStd ty = raise Fail(concat[
          "bogus function type ", CPSTyUtil.toString ty])
    and cvtStdFunTyAuxKwn (CPSTy.T_Fun(argTys, retTys), (args, rets)) = let
          fun cvtTy' (ty, x) = cvtTy (ty, CFA.valueOf x)
          fun cvtStdContTy' (ty, x) = cvtStdContTy (ty, CFA.valueOf x)
          in
            CFGTy.T_KnownFunc{
              clos = CFGTy.T_Any,
              args = (ListPair.mapEq cvtTy' (argTys, args)) @ 
                     (ListPair.mapEq cvtStdContTy' (retTys, rets))
            }
          end
      | cvtStdFunTyAuxKwn (ty, _) = raise Fail(concat[
          "bogus function type ", CPSTyUtil.toString ty])

  (* convert a continuation type to a standard-continuation type, guided by CFA values *)
    and cvtStdContTy (ty, v) = CFG.T_OpenTuple[cvtStdContTyAux (ty, v)]
    and cvtStdContTyAux (ty, CFA.TOP) = cvtStdContTyAuxStd ty
      | cvtStdContTyAux (ty, CFA.BOT) = cvtStdContTyAuxStd ty
      | cvtStdContTyAux (ty, CFA.LAMBDAS fs) = 
        if CPS.Var.Set.numItems fs = 0
        then cvtStdContTyAuxStd ty
        else 
        let
          val SOME f = CPS.Var.Set.find (fn _ => true) fs (*If fs is empty, then this returns NONE and fails*)
          val CPS.VK_Cont (CPS.FB {params, rets = [], ...}) = CPS.Var.kindOf f
          in
             if CFA.isEscaping f
                then cvtStdContTyAuxStd ty
             else cvtStdContTyAuxKwn (ty, params)
          end
      | cvtStdContTyAux (ty, v) = raise Fail(concat[
          "bogus continuation type ", CPSTyUtil.toString ty, " : ", CFA.valueToString v])
    and cvtStdContTyAuxStd (CPSTy.T_Cont(argTys)) =
          CFGTyUtil.stdContTy(CFGTy.T_Any, List.map cvtTyTop argTys)
      | cvtStdContTyAuxStd (CPSTy.T_Any) = 
          CFGTyUtil.stdContTy(CFGTy.T_Any, [CFGTy.T_Any])
      | cvtStdContTyAuxStd ty = raise Fail(concat[
          "bogus continuation type ", CPSTyUtil.toString ty])
    and cvtStdContTyAuxKwn (CPSTy.T_Cont(argTys), args) = let
          fun cvtTy' (ty, x) = cvtTy (ty, CFA.valueOf x)
          in
            CFGTyUtil.kwnContTy(CFGTy.T_Any, ListPair.mapEq cvtTy' (argTys, args))
          end
      | cvtStdContTyAuxKwn (ty, _) = raise Fail(concat[
          "bogus continuation type ", CPSTyUtil.toString ty])

    fun cvtTyOfVar x = 
       ((cvtTy (CPS.Var.typeOf x, CFA.valueOf x))
        handle Fail s => raise Fail(concat["cvtTyOfVar(", CPS.Var.toString x, ") ==> ", s]))
        
    val cvtTyOfVar = fn x => let
          val ty = CPS.Var.typeOf x
          val v = CFA.valueOf x
          val ty' = cvtTyOfVar x
          in
            if Controls.get ClosureControls.debug
              then print(concat[
                "cvtTyOfVar(", CPS.Var.toString x, " : ",
                "typeOf => ", CPSTyUtil.toString ty, " ; ",
                "valueOf => ", CFA.valueToString v, ") => ", CFGTyUtil.toString ty', "\n"])
              else ();
            ty'
          end

    (* a function call's return type is the type of the args to the retk *)
    fun retTyOf retk = let
        val (CFGTy.T_OpenTuple [retkTy]) = cvtTyOfVar retk  (* consult CFA to see what the type is. *)
        val argTys = (case retkTy
                       of CFGTy.T_StdCont {args,...} => args
                        | CFGTy.T_KnownFunc {args, ...} => args
                        | _ => raise Fail "dunno about this one"
                      (* esac *))
    in
        argTys
    end


  (* assign labels to functions and continuations *)
    local
      val {getFn : CPS.var -> CFG.label, setFn, ...} =
            CPS.Var.newProp (fn f => raise Fail(concat["labelOf(", CPS.Var.toString f, ")"]))
    in
    fun assignLabels lambda = let
          fun assignFB (CPS.FB{f, body, ...}) = let
                val fTy = CPS.Var.typeOf f
                val fVal = CFA.valueOf f
                val lab = CFG.Label.new(CPS.Var.nameOf f, cvtStdFunTyAux(fTy, fVal))
                in
                  setFn (f, lab);
                  assignExp body
                end
          and assignKB (CPS.FB{f, body, ...}) = if CC.isJoinCont f
		then (* this continuation will map to a block, so no label now *)
		  (assignExp body ; ST.tick cntJoinContOpt)
		else let
		  val fTy = CPS.Var.typeOf f
		  val fVal = CFA.valueOf f
		  val lab = CFG.Label.new(CPS.Var.nameOf f, cvtStdContTyAux(fTy, fVal))
		  in
		    setFn (f, lab);
		    assignExp body
		  end
          and assignExp (CPS.Exp(_, t)) = (case t
		 of (CPS.Let(_, _, e)) => assignExp e
		  | (CPS.Fun(fbs, e)) => (List.app assignFB fbs; assignExp e)
		  | (CPS.Cont(kb, e)) => (assignKB kb; assignExp e)
		  | (CPS.If(_, e1, e2)) => (assignExp e1; assignExp e2)
		  | (CPS.Switch(_, cases, dflt)) => (
		      List.app (assignExp o #2) cases;
		      Option.app assignExp dflt)
		  | _ => ()
		(* end case *))
          in
            assignFB lambda
          end
    val setLabel = setFn
    val labelOf = getFn
    end

    datatype loc
      = Local of CFG.var        (* bound in the current function *)
      | Global of int           (* at the ith slot of the current closure *)
      | EnclFun                 (* the enclosing function (or one that shares the *)
                                (* same closure). *)
      | EnclCont		(* the enclosing continuation function *) (* NOTE(kavon): this seems unused *)
      | JoinCont		(* a join continuation *)
      | RetCont			(* a return continuation *)
      | Extern of CFG.label	(* bound to an external variable (e.g., C function *)

  (* an envrionment for mapping from CPS variables to CFG variables.  We also
   * track the current closure.
   *)
    datatype env = E of {ep : CFG.var, env : loc VMap.map}

(* +DEBUG *)
    fun locToString (Local x) = concat["L(", CFG.Var.toString x, ")"]
      | locToString (Global i) = concat["G(", Int.toString i, ")"]
      | locToString EnclFun = "EnclFun"
      | locToString EnclCont = "EnclCont"
      | locToString JoinCont = "JoinCont"
      | locToString RetCont = "RetCont"
      | locToString (Extern lab) = concat["X(", CFG.Label.toString lab, ")"]
    fun prEnv (E{ep, env}) = let
	  fun f (x, loc) = print(concat[
		  "\n    ", CPS.Var.toString x, " --> ", locToString loc
		])
          in
            print(concat["E{ep = ", CFG.Var.toString ep, " : ", CFGTyUtil.toString(CFG.Var.typeOf ep), "\n"]);
            print "  env = {";
            VMap.appi f env;
            print "}\n}\n"
          end
(* -DEBUG *)

    fun envPtrOf (E{ep, ...}) = ep

    fun newEnv externEnv ep = E{ep = ep, env = externEnv}

  (* create a new environment that gives a fresh name to the environment pointer *)
    fun envWithFreshEP (E{ep, env}) = E{ep = CFG.Var.copy ep, env=env}

    fun insertVar (E{ep, env}, x, x') = E{ep=ep, env=VMap.insert(env, x, x')}

    fun findVar' (E{env, ...}, x) = (case VMap.find(env, x)
          of SOME loc => SOME loc
           | NONE => NONE
          (* end case *))
    fun findVar (env, x) = (case findVar'(env, x)
          of SOME loc => loc
           | NONE => raise Fail("unbound variable " ^ CPS.Var.toString x)
          (* end case *))

  (* create a new CFG variable for a CPS variable *)
    fun newVar x = CFG.Var.new (
          CPS.Var.nameOf x,
          cvtTyOfVar x)
    val newVar = fn x => let
          val x' = newVar x
          in
            if Controls.get ClosureControls.debug
              then print(concat[
                "newVar(", CPS.Var.toString x, " : ", CPSTyUtil.toString (CPS.Var.typeOf x), ") => ", 
                    CFG.Var.toString x', " : ", CFGTyUtil.toString (CFG.Var.typeOf x') , "\n"])
              else ();
            x'
          end

  (* return the type use to represent the environment type *)
    fun envPtrType [] = CFGTy.T_Enum 0w0
      | envPtrType tys = CFGTy.T_Tuple(false, tys)

    fun newEP ty = let
          val x' = CFG.Var.new ("ep", ty)
          in
            if Controls.get ClosureControls.debug
              then print(concat[
                "newEP(_) => ", CFG.Var.toString x', "\n"])
              else ();
            x'
          end

(*
    fun newEP [] =
      (* NOTE: T_Enum(0w0) is the correct type here, but that causes problems in CheckCFG. *)
          CFG.Var.new ("ep", CFGTy.T_Any)
      | newEP tys = CFG.Var.new ("ep", CFGTy.T_Tuple(false, tys))
*)

    fun newLocal (env, x) = let
          val x' = newVar x
          in
            (insertVar(env, x, Local x'), x')
          end
 
    fun newLocalVar (env, x, ty) = let
          val x' = CFG.Var.new (CPS.Var.nameOf x, ty)
          in
            (insertVar(env, x, Local x'), x')
          end
 
    fun newLocals (E{ep, env}, xs) = let
          fun f (x, (env, xs')) = let
                val x' = newVar x
                in
                  (VMap.insert(env, x, Local x'), x'::xs')
                end
          val (env, xs) = List.foldl f (env, []) xs
          in
            (E{ep=ep, env=env}, List.rev xs)
          end
 
    fun bindLabel lab = let
          val labVar = CFG.Var.new(CFG.Label.nameOf lab, CFG.Label.typeOf lab)
          in
            (CFG.mkLabel(labVar, lab), labVar)
          end
    val bindLabel = fn lab => let
          val (bind, x') = bindLabel lab
          in
            if Controls.get ClosureControls.debug
              then print(concat[
                "bindLabel(", CFG.Label.toString lab, ") => ", CFG.Var.toString x', "\n"])
              else ();
            (bind, x')
          end

  (* lookup a CPS variable in the environment.  If it has to be fetched from
   * a closure, we introduce a new temporary for it.
   * QUESTION: should we cache the temp in the environment?
   *)
    fun lookupVar (E{ep, env}, x) = (case VMap.find(env, x)
           of SOME(Local x') => ([], x')
            | SOME(Global i) => let (* fetch from closure *)
                val tmp = newVar x
                in
                  ([CFG.mkSelect(tmp, i, ep)], tmp)
                end
            | SOME EnclFun => let (* build <ep, cp> pair *)
                val (b, lab) = bindLabel(labelOf x)
		val ty = CFGTy.T_Tuple(false, [CFG.Var.typeOf ep, CFG.Var.typeOf lab])
                val tmp = CFG.Var.new(CPS.Var.nameOf x, ty)
                in
                  ([CFG.mkAlloc(tmp, ty, [ep, lab]), b], tmp)
                end
	    | SOME EnclCont => ([], ep)
	    | SOME JoinCont =>
		raise Fail("unexpected join continuation " ^ CPS.Var.toString x)
	    | SOME(Extern lab) => let
                val tmp = newVar x
                in
                  ([CFG.mkLabel(tmp, lab)], tmp)
                end
                
        | SOME RetCont => raise Fail(concat[
		  "unbound retk ", CPS.Var.toString x, "; ep = ", CFG.Var.toString ep,
          "\n did you forget to filter it out?"
		])
        
        | NONE => raise Fail(concat[
		  "unbound variable ", CPS.Var.toString x, "; ep = ", CFG.Var.toString ep
		])
          (* end case *))
    val lookupVar = fn (env, x) => let
          val (binds, x') = lookupVar (env, x)
          in
            if Controls.get ClosureControls.debug
              then print(concat[
                "lookupVar(_,", CPS.Var.toString x, ") => ", CFG.Var.toString x', "\n"])
              else ();
            (binds, x')
          end

    fun lookupVars (env, xs) = let
          fun lookup ([], binds, xs) = (binds, xs)
            | lookup (x::xs, binds, xs') = let
                val (b, x) = lookupVar(env, x)
                in
                  lookup (xs, b @ binds, x::xs')
                end
          in
            lookup (List.rev xs, [], [])
          end

    fun isPtr var = case (CPSTyUtil.kindOf (CPS.Var.typeOf var))
                     of CPSTy.K_UNIFORM => true
                      | CPSTy.K_BOXED => true
                      | _ => false
                             
  (* given a set of free CPS variables that define the environment of a function, create the
   * argument variables and bindings to build the closure and the parameter variables and
   * environment for the function's body.
   *)
    fun mkFunClosure externEnv (env, fv) = let
          fun mkArgs (x, (i, binds, clos, xs)) = let
                val (b, x') = lookupVar(env, x)
                in
                  (i+1, b@binds, VMap.insert(clos, x, Global i), x'::xs)
                end
          val (fvPtr, fvRaw) = CPS.Var.Set.partition isPtr fv
          val (i, binds, clos, cfgArgs) =
                CPS.Var.Set.foldl mkArgs (0, [], externEnv, []) fvPtr
          val (_, binds, clos, cfgArgs) =
                CPS.Var.Set.foldl mkArgs (i, binds, clos, cfgArgs) fvRaw
          val cfgArgs = List.rev cfgArgs
	  val epTy = envPtrType (List.map CFG.Var.typeOf cfgArgs)
          val ep = newEP epTy
	  val ep' = newEP epTy
	  val bindEP = (case epTy
		 of CFGTy.T_Enum _ => CFG.mkConst(ep', Literal.Enum 0w0, epTy)
		  | _ => CFG.mkAlloc(ep', epTy, cfgArgs)
		(* end case *))
          in
            (bindEP::binds, ep', cfgArgs, E{ep = ep, env = clos})
          end

  (* given a set of free CPS variables that define the environment of a continuation, create the
   * argument variables and bindings to build the closure and the parameter variables and
   * environment for the continuation's body.
   *)
    fun mkContClosure externEnv (env, params, fv, mkContTy) = let
          val params' = List.map newVar params
          fun mkArgs (x, (i, binds, clos, xs)) = let
                val (b, x') = lookupVar(env, x)
                in
                  (i+1, b@binds, VMap.insert(clos, x, Global i), x'::xs)
                end
	(* the initial environment is the externs plus the parameters *)
	  val env = ListPair.foldl
		(fn (x, x', env) => VMap.insert(env, x, Local x'))
		  externEnv (params, params')
          val (fvPtr, fvRaw) = CPS.Var.Set.partition isPtr fv
          val (i, binds, clos, cfgArgs) =
                CPS.Var.Set.foldl mkArgs (1, [], env, []) fvPtr
          val (_, binds, clos, cfgArgs) =
                CPS.Var.Set.foldl mkArgs (i, binds, clos, cfgArgs) fvRaw
          val cfgArgs = List.rev cfgArgs
	  val epTy = envPtrType (mkContTy(CFGTy.T_Any, List.map CFG.Var.typeOf params')
                :: List.map CFG.Var.typeOf cfgArgs)
          val ep = newEP epTy
          in
            (binds, cfgArgs, E{ep = ep, env = clos}, params')
          end

    fun convert (m as CPS.MODULE{name, externs, body}) = let
          val blocks = ref []
        (* construct an initial environment that maps the CPS externs to CFG labels *)
          val (externs, externEnv) = let
                fun cvt (CFunctions.CFun{var, name, retTy, argTys, attrs, varArg}, (cfs, env)) = let
                      val lab = CFG.Label.new(name, cvtTyOfVar var)
                      val cf = CFG.mkCFun{var=lab, name=name, argTys=argTys, retTy=retTy, attrs=attrs, varArg=varArg}
                      in
                        (cf::cfs, VMap.insert(env, var, Extern lab))
                      end
                in
                  List.foldl cvt ([], VMap.empty) externs
                end
          val newEnv = newEnv externEnv
          val mkFunClosure = mkFunClosure externEnv
          val mkContClosure = mkContClosure externEnv
        (* convert an expression to a CFG FUNC; note that this function will convert
         * any nested functions first.
         *)
          fun cvtExp (env, params, cpsLab, lab, e) = let
                val () = if Controls.get ClosureControls.debug
		      then (print(concat[
			  "********************\ncvtExp: lab = ", CFG.Label.toString lab, "(",
                          CPS.Var.toString cpsLab, ")\n"
			]);
			prEnv env)
		      else ()
                (* Convert an expression into an entry block and a list of any additional blocks.
                 * A CPS function with a single conditional turns into an entry block containing
                 * the code before the conditional with a transfer that is the conditional and a
                 * list of blocks corresponding to what the true and false branches of the conditional
                 * were converted into.
                 *)
                fun cvt (env, args, cpsExp as (CPS.Exp(_, e)), stms, encl) : CFG.block * CFG.block list = let
                     fun cvtBranch (lab, e, encl) = let
                            val needsEP = ref false
                            val argEP = envPtrOf env
                            val paramEP = CFG.Var.copy argEP
                            val branchEnv = newEnv paramEP
                            fun f (x, (bEnv, args, params)) = (case findVar(env, x)
                                   of Local x' => let
                                        val (bEnv', x'') = newLocal(bEnv, x)
                                        in
                                          (bEnv', x' :: args, x'' :: params)
                                        end
                                    | Global i => (
                                        needsEP := true; 
                                        (insertVar(bEnv, x, Global i), args, params))
                                    | EnclFun => (
                                        needsEP := true;
                                        (insertVar(bEnv, x, EnclFun), args, params))
                                    | EnclCont => (
                                        needsEP := true;
                                        (insertVar(bEnv, x, EnclCont), args, params))
                                        
                                    | RetCont => (insertVar(bEnv, x, RetCont), args, params)
                                    | JoinCont => (bEnv, args, params)
                                    | Extern _ => raise Fail "unexpected extern in free-var list"
                                  (* end case *))
                            val (branchEnv, args, params) =
                                  CPS.Var.Set.foldr f (branchEnv, [], []) (FV.freeVarsOfExp e)
			  (* if there are any free globals in e, then we include
			   * the environment pointer as an argument.
			   *)
                            val (args, params) = if !needsEP
                                  then (argEP :: args, paramEP :: params)
                                  else (args, params)
                            val lab' = CFG.Label.new(
                                  lab,
                                  CFGTy.T_Block{args = List.map CFG.Var.typeOf params})
                            in
                              (cvtExp (branchEnv, params, encl, lab', e), args)
                            end
                      in
                        case e
                         of CPS.Let(lhs, rhs, e) => let
                              val (binds, env') = cvtRHS(env, lhs, rhs)
                              in
                                cvt (env', args, e, binds @ stms, encl)
                              end
                          | CPS.Fun(fbs, e) => let
                              val (binds, env) = cvtFunc(env, fbs)
                              in
                                cvt (env, args, e, binds @ stms, encl)
                              end
                          | CPS.Cont(fb, e) => let
                              val (binds, env, joinBlocks) = cvtCont(env, fb)
                              
                              val _ = let
                                    val (CPS.FB{f,...}) = fb
                                  in
                                    print ("env after cvtCont(" ^ (CPS.Var.toString f) ^ "):\n")
                                  end
                              val _ = prEnv env
                              
                              val (start, body) = cvt (env, args, e, binds @ stms, encl)
                              val body = joinBlocks@body
                              in
                                (start, body)
                              end
                          | CPS.If(cond, e1, e2) => let
			      val (mkC, args') = CondUtil.explode cond
			      val (binds, args') = lookupVars (env, args')
                              val ((tb as CFG.BLK{lab=tlab,...}, r), targs) = cvtBranch ("then", e1, encl)
                              val ((fb as CFG.BLK{lab=flab,...}, rr), fargs) = cvtBranch ("else", e2, encl)
			      in
                                (CFG.mkBlock(lab, params, rev (binds@stms),
                                     CFG.If(mkC args', (tlab,targs), (flab,fargs))),
                                 tb::fb::r@rr)
                              end
                          | CPS.Switch(x, cases, dflt) => let
                              val (binds, x) = lookupVar(env, x)
                              val cs = List.map (fn (i, c) => (i, cvtBranch ("case", c, encl))) cases
                              val cJumps = List.map (fn (i, ((cb as CFG.BLK{lab=clab,...}, _), cargs)) =>
                                                        (i, (clab,cargs))) cs
                              val rr = List.foldr (fn ((_, ((b, bs), _)), rs) => b::bs@rs) [] cs
                              val d = case dflt
                                       of NONE => NONE
                                        | SOME e => SOME (cvtBranch ("default", e, encl))
                              val (dJump, rr) = case d
                                                 of NONE => (NONE, rr)
                                                  | SOME ((db as CFG.BLK{lab=dlab,...}, rs), dargs) =>
                                                    (SOME (dlab,dargs), db::rs@rr)
                                                        
			      in
                                (CFG.mkBlock(lab, params, rev (binds@stms),
                                     CFG.Switch(x, cJumps, dJump)),
                                 rr)
                              end
                          | CPS.Apply(f, args', rets) => let
                                val isTail = CC.isTailApply cpsExp
                                val (binds, xfer) = cvtApply (env, f, args', rets, isTail)
                            in
                                (CFG.mkBlock(lab, params, rev (binds@stms), xfer), [])
                            end
                          | CPS.Throw(k, args') => let
                                val (binds, xfer) = cvtThrow (env, k, args')
                            in
                                (CFG.mkBlock(lab, params, rev (binds@stms), xfer), [])
                            end
                        (* end case *)
                      end
                in
                  cvt (env, [], e, [], cpsLab)
                end
        (* convert a CPS RHS to a list of CFG expressions, plus a new environment *)
          and cvtRHS (env, lhs, rhs) = (case (newLocals(env, lhs), rhs)
                 of ((env, lhs), CPS.Var ys) => let                              
                      val (binds, ys) = lookupVars (env, ys)
                      in
                        ([CFG.mkVar(lhs, ys)] @ binds, env)
                      end
                  | ((env, [x]), CPS.Const(lit, ty)) => ([CFG.mkConst(x, lit, cvtTyTop ty)], env)
                  | ((env, [x]), CPS.Cast(ty, y)) => let
                      val (binds, y') = lookupVar(env, y)
                      val convertedTy = cvtTy(ty, CFA.valueOf y)
                      in
                        ([CFG.mkCast(x, convertedTy, y')] @ binds, env)
                      end
                  | ((env, [x]), CPS.Select(i, y)) => let
                      val (binds, y) = lookupVar(env, y)
                      in
                        ([CFG.mkSelect(x, i, y)] @ binds, env)
                      end
                  | ((env, []), CPS.Update(i, y, z)) => let
                      val (binds, y) = lookupVar(env, y)
                      val (binds', z) = lookupVar(env, z)
                      in
                        ([CFG.mkUpdate(i, y, z)] @ binds' @ binds, env)
                      end
                  | ((env, [x]), CPS.AddrOf(i, y)) => let
                      val (binds, y) = lookupVar(env, y)
                      in
                        ([CFG.mkAddrOf(x, i, y)] @ binds, env)
                      end
                  | ((env, [x]), CPS.Alloc(ty, ys)) => let
                      val (binds, ys) = lookupVars (env, ys)
                      in
(* FIXME: should the argument be TOP here? *)
                        ([CFG.mkAlloc(x, cvtTy(ty, CFA.TOP), ys)] @ binds, env)
                      end
                  | ((env, [x]), CPS.Promote y) => let
                      val (binds, y) = lookupVar (env, y)
                      in
                        ([CFG.mkPromote(x, y)] @ binds, env)
                      end
                  | ((env, []), CPS.Prim p) => let
                      val (mkP, args) = PrimUtil.explode p
                      val (binds, args) = lookupVars (env, args)
                      in
                        ([CFG.mkPrim0(mkP args)] @ binds, env)
                      end
                  | ((env, [x]), CPS.Prim p) => let
                      val (mkP, args) = PrimUtil.explode p
                      val (binds, args) = lookupVars (env, args)
                      in
                        ([CFG.mkPrim(x, mkP args)] @ binds, env)
                      end
                  | ((env, res), CPS.CCall(f, args)) => let
                      val (binds, f::args) = lookupVars (env, f::args)
                      in
                        ([CFG.mkCCall(res, f, args)] @ binds, env)
                      end
                  | ((env, [vp]), CPS.HostVProc) => ([CFG.mkHostVProc(vp)], env)
                  | ((env, [x]), CPS.VPLoad(offset, vp)) => let
                      val (binds, vp) = lookupVar(env, vp)
                      in
                        ([CFG.mkVPLoad(x, offset, vp)] @ binds, env)
                      end
                  | ((env, []), CPS.VPStore(offset, vp, x)) => let
                      val (binds, [vp, x]) = lookupVars(env, [vp, x])
                      in
                        ([CFG.mkVPStore(offset, vp, x)] @ binds, env)
                      end
                  | ((env, [x]), CPS.VPAddr(offset, vp)) => let
                      val (binds, vp) = lookupVar(env, vp)
                      in
                        ([CFG.mkVPAddr(x, offset, vp)] @ binds, env)
                      end
                  | (_, rhs) => raise Fail("ill-formed RHS binding: " ^ CPSUtil.rhsToString rhs)
                (* end case *))
        (* create a standard function convention for a list of parameters *)
          and stdFuncConvention (env, args, [ret, exh]) = let
                val env = envWithFreshEP env
                val (env, args) = newLocals (env, args)
                val (env, exh) = newLocal(env, exh)
                val env = insertVar(env, ret, RetCont)
                val retTys = retTyOf ret
                val clos = envPtrOf env
                val conv = CFG.StdDirectFunc { clos = clos, exh = exh, ret = retTys }
                val convTy = CFGTy.T_StdDirFun {
                        clos = CFG.Var.typeOf clos,
                        args = List.map CFG.Var.typeOf args,
                        ret = retTys,
                        exh = CFG.Var.typeOf exh
                      }
                in
                  (env, args, conv, convTy)
                end
            | stdFuncConvention (env, args, rets as [_]) = 
                kwnFuncConvention (env, args, rets)
            | stdFuncConvention (env, args, rets) =
                raise Fail "non-standard apply convention"
        (* create a known function convention for a list of parameters *)
          and kwnFuncConvention (env, args, [ret, exh]) = let
                val env = envWithFreshEP env
                val (env, args) = newLocals (env, args)
                val (env, exh) = newLocal (env, exh)
                val env = insertVar(env, ret, RetCont)
                val retTys = retTyOf ret
                val clos = envPtrOf env
                val conv = CFG.KnownDirectFunc {
                        clos = clos,
                        ret = retTys
                      }
                val convTy = CFGTy.T_KnownDirFunc {
                        clos = CFG.Var.typeOf clos,
                        args = List.map CFG.Var.typeOf (args @ [exh]),
                        ret = retTys
                      }
                in
                  (env, args @ [exh], conv, convTy)
                end
        (* convert bound functions *)
          and cvtFunc (env, fbs) = let
              (* the functions share a common environment tuple *)
                val (binds, ep, clos, sharedEnv) =
                      mkFunClosure (env, FV.envOfFun(funVar(hd fbs)))
              (* map the names of the bound functions to EnclFun *)
                val sharedEnv = List.foldl
                      (fn (fb, env) => insertVar(env, funVar fb, EnclFun)) 
                      sharedEnv fbs
              (* convert an individual function binding; this includes creating its
               * code-pointer/environment-pointer pair and converting the function's body.
               *)
                fun cvtFB (CPS.FB{f, params, rets, body}, (binds, env)) = let
                      val (fbEnv, params, conv, convTy) = 
                            if CFA.isEscaping f
                              then stdFuncConvention (sharedEnv, params, rets)
                              else kwnFuncConvention (sharedEnv, params, rets)
                      val lab = labelOf f
                      val () = CFG.Label.setType (lab, convTy)
                      val (bindLab, labVar) = bindLabel lab
                      val (env', f') = newLocal (env, f)
		      val (env', f') = newLocalVar (env, f,
			    CFGTy.T_Tuple(false, [CFG.Var.typeOf ep, CFG.Var.typeOf labVar]))
                      val binds = CFG.mkAlloc(f', CFG.Var.typeOf f', [ep, labVar])
			    :: bindLab :: binds
                      (* convert the function itself *)
                      val (start, body) = cvtExp (fbEnv, params, f, lab, body)
                      in
                        finishFunc (lab, conv, start, body);
                        (binds, env')
                      end
                in
                   List.foldl cvtFB (binds, env) fbs
                end
          and finishFunc (lab, conv, start, body) = let
              val func = CFG.mkLocalFunc (lab, conv, start, body)
          in
              if Controls.get ClosureControls.debug
	      then print(concat[
			 "******************** finishFunc ", CFG.Label.toString lab, "\n"
			])
	      else ();
              blocks := func :: !blocks
          end
        (* convert a bound continuation *)
          and cvtCont (env, CPS.FB{f=k, params, body, ...}) = let
                fun cvtJoinK () = let
                
            		(* f is a join continuation, so we will translate it to a *
             		 * block.  We have to extend its parameters with the locally *
             		 * bound free variables. *
             		 *)
            		  val needsEP = ref false
            		  fun f (x, (bEnv, params)) = (case findVar(env, x)
            			 of Local _ => let
            			      val (bEnv', x') = newLocal(bEnv, x)
            			      in
            				(bEnv', x' :: params)
            			      end
            			  | Global i => (
            			      needsEP := true;
            			      (insertVar(bEnv, x, Global i), params))
            			  | EnclFun => (
            			      needsEP := true;
            			      (insertVar(bEnv, x, EnclFun), params))
            			  | EnclCont => (
            			      needsEP := true;
            			      (insertVar(bEnv, x, EnclCont), params))
                          | RetCont => (insertVar(bEnv, x, RetCont), params)
            			  | JoinCont => (bEnv, params)
            			  | Extern _ => raise Fail "unexpected extern in free-var list"
            			(* end case *))
            		  val paramEP = CFG.Var.copy (envPtrOf env)
            		  val (bodyEnv, params) = newLocals (newEnv paramEP, params)
            		  val (bodyEnv, params) =
            			CPS.Var.Set.foldr f (bodyEnv, params) (FreeVars.envOfFun k)
            		  val bodyEnv = insertVar (bodyEnv, k, JoinCont)  (* to support recursive conts *)
            	       (* if there are any free globals in e, then we include *
                            * the environment pointer as an argument. *)
            		  val params = if !needsEP then paramEP :: params else params
            		  val lab = CFG.Label.new(
            			CPS.Var.nameOf k,
            			CFGTy.T_Block{args = List.map CFG.Var.typeOf params})
            		  val _ = setLabel (k, lab) 
                              val (start, body) = cvtExp (bodyEnv, params, k, lab, body)
            		  in
            		    ([], insertVar (env, k, JoinCont), start::body)
            		  end
                      
                fun cvtRetK () = let
                    (* handle a return continuation. *)
                    val needsEP = ref false
                    fun f (x, (bEnv, params)) = (case findVar(env, x)
                       of Local _ => let
                            val (bEnv', x') = newLocal(bEnv, x)
                            in
                          (bEnv', x' :: params)
                            end
                        | Global i => (
                            needsEP := true;
                            (insertVar(bEnv, x, Global i), params))
                        | EnclFun => (
                            needsEP := true;
                            (insertVar(bEnv, x, EnclFun), params))
                        | EnclCont => (
                            needsEP := true;
                            (insertVar(bEnv, x, EnclCont), params))
                        | RetCont => (insertVar(bEnv, x, RetCont), params)
                        | JoinCont => (bEnv, params)
                        | Extern _ => raise Fail "unexpected extern in free-var list"
                      (* end case *))
                      (* NOTE other than not adding k to the environment of its body, this is identical to
                         how we handle joink's, except RetCont and not JoinCont etc. so clean this up! TODO *)
                    val paramEP = CFG.Var.copy (envPtrOf env)
                    val (bodyEnv, params) = newLocals (newEnv paramEP, params)
                    val (bodyEnv, params) =
                      CPS.Var.Set.foldr f (bodyEnv, params) (FreeVars.envOfFun k)
                    (*val bodyEnv = insertVar (bodyEnv, k, JoinCont)  (* to support recursive conts *)*)
                     (* if there are any free globals in e, then we include *
                          * the environment pointer as an argument. *)
                    val params = if !needsEP then paramEP :: params else params
                    val lab = CFG.Label.new(
                      CPS.Var.nameOf k,
                      CFGTy.T_Block{args = List.map CFG.Var.typeOf params})
                    val _ = setLabel (k, lab) 
                            val (start, body) = cvtExp (bodyEnv, params, k, lab, body)
                in
                  ([], insertVar (env, k, RetCont), start::body)
                end
                
                
                
                
                
                fun cvtExnK () = raise Fail "don't know how we will convert exh conts yet!"
          in
            (case CC.kindOfCont k
                of CC.JoinCont => cvtJoinK () (* TODO make sure the joink opt is always on *)
                 | CC.ReturnCont => cvtRetK ()
                 | CC.ExnCont => cvtExnK ()
                 | x => raise Fail ((CC.kindToString x) ^ " conts are unexpected.")
            (* esac *))
          end
          
        (* convert an apply *)
          and cvtApply (env, f, args, rets, isTail) = (case CFA.valueOf f
                 of CFA.TOP => cvtStdApply (env, f, NONE, args, rets, isTail)
                  | CFA.BOT => cvtStdApply (env, f, NONE, args, rets, isTail)
                  | CFA.LAMBDAS gs => let
                      val SOME g = CPS.Var.Set.find (fn _ => true) gs
                      val gs = CPS.Var.Set.filter (not o CFA.isProxy) gs
                      val fTgt = if CPS.Var.Set.numItems gs = 1 
                                    then CPS.Var.Set.find (fn _ => true) gs
                                 else NONE
                      in
                        if CFA.isEscaping g
                          then cvtStdApply (env, f, fTgt, args, rets, isTail)
                          else cvtKwnApply (env, f, fTgt, args, rets, isTail)
                      end
                (* end case *))
          and cvtStdApply (env, f, fTgt, args, rets as [_, _], isTail) = let
                val (argBinds, args) = lookupVars(env, args)
                val (retBinds, [ret, exh]) = lookupVars(env, rets)
                fun bindEP () = let
                      val (fBinds, f') = lookupVar(env, f)
                      val ep = CFG.Var.new (CPS.Var.nameOf f ^ "_ep", CFGTy.T_Any)
                      in
                        (CFG.mkSelect(ep, 0, f') :: fBinds, f', ep)
                      end
                val (binds, xfer) = let
                      val (cp, ep, binds') = (case fTgt
                             of SOME g => let
                                  val (gBind, cp) = bindLabel (labelOf g)
                                  in
                                    case findVar'(env, g)
                                     of SOME EnclFun => (cp, envPtrOf env, [gBind])
                                      | _ => let
                                          val (epBinds, _, ep) = bindEP ()
                                          in
                                            (cp, ep, gBind :: epBinds)
                                          end
                                    (* end case *)
                                  end
                              | NONE => let
                                  val (epBinds, f', ep) = bindEP ()
                                  val cp = CFG.Var.new(
                                        CFG.Var.nameOf f',
                                        CFGTyUtil.select(CFG.Var.typeOf f', 1))
                                  val cpBind = CFG.mkSelect(cp, 1, f')
                                  in
                                    (cp, ep, cpBind :: epBinds)
                                  end
                            (* end case *))
                      val xfer = CFG.StdApply{
                              f = cp,
                              clos = ep,
                              args = args,
                              ret = ret,
                              exh = exh
                            }
                      in
                        (binds', xfer)
                      end
                in
                  (binds @ retBinds @ argBinds, xfer)
                end
            | cvtStdApply (env, f, fTgt, args, rets as [_], isTail) = 
                cvtKwnApply (env, f, fTgt, args, rets, isTail)
            | cvtStdApply (env, f, fTgt, args, rets, isTail) = 
                raise Fail "non-standard apply convention"
          and cvtKwnApply (env, f, fTgt, args, rets, isTail) = let
                
                val _ = print ("hit an apply to arg: " ^ ((CPS.Var.toString o List.hd) args) ^ "\n")
                
                val (argBinds, args) = lookupVars(env, args)
                
                fun bindEP () = let
                      val (fBinds, f') = lookupVar(env, f)
                      val ep = CFG.Var.new (CPS.Var.nameOf f ^ "_ep", CFGTy.T_Any)
                  in
                    (CFG.mkSelect(ep, 0, f') :: fBinds, f', ep)
                  end
                      
                val (cp, ep, binds') = (case fTgt
                     of SOME g => let
                          val (gBind, cp) = bindLabel (labelOf g)
                          in
                            case findVar'(env, g)
                             of SOME EnclFun => (cp, envPtrOf env, [gBind])
                              | _ => let
                                  val (epBinds, _, ep) = bindEP ()
                                  in
                                    (cp, ep, gBind :: epBinds)
                                  end
                            (* end case *)
                          end
                      | NONE => let
                          val (epBinds, f', ep) = bindEP ()
                          val cp = CFG.Var.new(
                                CFG.Var.nameOf f',
                                CFGTyUtil.select(CFG.Var.typeOf f', 1))
                          val cpBind = CFG.mkSelect(cp, 1, f')
                          in
                            (cp, ep, cpBind :: epBinds)
                          end
                    (* end case *))
                
                fun doTailCall () = let
                    val xfer = CFG.Call {
                            f = cp,
                            clos = ep,
                            args = args,
                            next = NONE
                          }
                    in
                      (binds' @ argBinds, xfer)
                    end
                    
                    (*
                    cvtJoinThrow (env, k, args) = let
                              val (argBinds, args) = lookupVars(env, args)
              		val needsEP = ref false
              		fun f (x, args) = (case findVar(env, x)
              		       of Local x' => x' :: args
              			| Extern _ => raise Fail "unexpected extern in free-var list"
              			| _ => (needsEP := true; args)
              		      (* end case *))
              		val args = CPS.Var.Set.foldr f args (FreeVars.envOfFun k)
              	     (* if there are any free globals in e, then we include
              	      * the environment pointer as an argument.
              	      *)
              		val args = if !needsEP then envPtrOf env :: args else args
              		in
              		  (argBinds, CFG.Goto(labelOf k, args))
              		end
                    *)
                    
                fun doCall () = let
                    
                    (* TODO: include the exn as an argument if its there *)
                    val (retk :: _) = rets
                    
                    val _ = prEnv env
                    
                    val needsEP = ref false
                    
                    fun f (x, args) = (case findVar(env, x)
                            of Local x' => x' :: args
                             | Extern _ => raise Fail "unexpected extern in free-var list"
                             | (RetCont | JoinCont) => args
                             | _ => (needsEP := true; args)
                            (* end case *))
                    
                    
                    val freeVars = CPS.Var.Set.foldr f nil (FreeVars.envOfFun retk)
                    
                    (* bindings for the values from the return throw *)
                    val lhs = let
                            val argTys = retTyOf retk
                                          
                            fun fresh ty = CFG.Var.new ("rv", ty)
                        in
                            List.map fresh argTys
                        end
                    
                    (* ep, free vars, retk's params *)
                    val retkArgs = freeVars @ lhs 
                    val retkArgs = if !needsEP then envPtrOf env :: retkArgs else retkArgs
                                    
                    val xfer = CFG.Call {
                            f = cp,
                            clos = ep,
                            args = args,
                            next = SOME (lhs, (labelOf retk, retkArgs))
                          }
                in
                    (binds' @ argBinds, xfer)
                end
            
            
          in
            if isTail
            then doTailCall()
            else doCall()
          end
          
          
          
        (* convert a throw *)
          and cvtThrow (env, k, args) = let
            val _ = print (concat (["handling throw to ", CPS.Var.toString k, " of "] @
                                    List.map CPS.Var.toString args @ ["\n"]))
          in
            (case CC.kindOfCont k
                  of CC.ParamCont => (case CC.checkRets(k, CC.contextOfThrow k)
                      (* is this a throw to one of the immediately enclosing 
                         continuations marked as an exnh or retk in this function? *)
                    of SOME(CC.ReturnCont) => 
                        (* this is a standard function return. *)
                          cvtReturnThrow(env, k, args)
                     
                     | SOME(CC.ExnCont) => raise Fail "can't handle raising an excemption atm"
                     | NONE => raise Fail "throw to a ret/exn continuation that's not the enclosing function's!"
                     (* esac *))
                  | (CC.JoinCont | CC.ReturnCont) => cvtJoinThrow (env, k, args)
                  | _ => raise Fail (
                      "encountered a throw that I can't handle: "
                      ^ (CC.kindToString o CC.kindOfCont) k
                      )
                  (* esac *))
          end

	  and cvtJoinThrow (env, k, args) = let
                val (argBinds, args) = lookupVars(env, args)
		val needsEP = ref false
		fun f (x, args) = (case findVar(env, x)
		       of Local x' => x' :: args
			| Extern _ => raise Fail "unexpected extern in free-var list"
            | (JoinCont | RetCont) => args
			| _ => (needsEP := true; args)
            (* TODO FIXME in regular CPS closure conversion, JoinCont bindings are not a reason to include an EP *)
		      (* end case *))
		val args = CPS.Var.Set.foldr f args (FreeVars.envOfFun k)
	     (* if there are any free globals in e, then we include
	      * the environment pointer as an argument.
	      *)
		val args = if !needsEP then envPtrOf env :: args else args
		in
		  (argBinds, CFG.Goto(labelOf k, args))
		end
        
        and cvtReturnThrow (env, k, args) = let (* TODO remove the k once things are working *)
            val (argBinds, args) = lookupVars(env, args)
        in
            (argBinds, CFG.Return args)
        end
        
        (* create the calling convention for the module *)
          fun cvtModLambda (CPS.FB{f, params, rets, body}) = let
                val ep = CFG.Var.new ("dummyEP", CFGTy.T_Any)
                val (env, params, conv, convTy) = 
                      stdFuncConvention (E{ep = ep, env = externEnv}, params, rets)
                val lab = labelOf f
                val () = CFG.Label.setType (lab, convTy)
                in
                  (lab, conv, cvtExp (env, params, f, lab, body))
                end
          in
            assignLabels body;
            let
                val (lab, conv, (start, body)) = cvtModLambda body
	        val init = CFG.mkExportFunc(lab, conv, start, body, Atom.toString name ^ "_init")
	    in
	      CFG.mkModule(name, externs, init::(!blocks))
	    end
          end

  end
