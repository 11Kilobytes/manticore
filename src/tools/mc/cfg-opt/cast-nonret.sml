(* cast-nonret.sml
 *
 * COPYRIGHT (c) 2019 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *)

structure CastNonRet : sig

    val transform : CFG.module -> CFG.module

  end = struct

    (* some callees of non-ret tail calls may have the wrong return type listed,
       even though they do not return. This pass fixes that up so LLVM is happy. *)

    structure C = CFG
    structure CV = CFG.Var

    fun doFn (f as C.FUNC{lab, entry, start, body}) = let
        val retTys = getRetTy entry
        val start' :: body' = map (doBlk retTys) (start::body)
    in
      C.mkLocalFunc (lab, entry, start', body')
    end

    and doBlk retTys (C.BLK{lab, args, body, exit}) = let
        val (newBody, newExit) = inspect (retTys, body, exit)
    in
        C.mkBlock (lab, args, newBody, newExit)
    end


    and inspect (retTys, body, exit) = (case exit
        of C.Call{f, clos, args, next=C.NK_NoReturn} => let
              val newTy = replaceRetTy retTys (CV.typeOf f)
              val newF = CV.new("nonRetCast", newTy)
            in (
                Census.inc newF ;
                (body @ [C.mkCast(newF, newTy, f)],
                 C.Call{ f = newF,
                         clos=clos,
                         args=args,
                         next=C.NK_NoReturn}
                )
              )
            end
         | _ => (body, exit)
        (* end case *))

    and replaceRetTy new fnTy = (case fnTy
        of CFGTy.T_KnownDirFunc {clos, args, ret = _} =>
              CFGTy.T_KnownDirFunc { clos=clos,
                                     args=args,
                                     ret = new }
         | CFGTy.T_StdDirFun {clos, args, exh, ret = _} =>
              CFGTy.T_StdDirFun {clos=clos,
                                 args=args,
                                 exh=exh,
                                 ret = new}

                (* should be able to handle others. just don't expect them. *)
         | _ => raise Fail "unexpected target of non-ret tail call."
         (* end *))

    and getRetTy (C.StdDirectFunc{ret,...}) = ret
      | getRetTy (C.KnownDirectConv{ret,...}) = ret
      | getRetTy _ = raise Fail "unexpected function type"

    fun transform (m as C.MODULE{name, externs, mantiExterns, code}) =
      if Controls.get BasicControl.direct
        then C.mkModule(name, externs, mantiExterns, map doFn code)
        else m

  end
