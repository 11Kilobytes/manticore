(* cps-opt-fn.sml
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *)

functor CPSOptFn (Spec : TARGET_SPEC) : sig

    val optimize : CPS.module -> CPS.module

  end = struct

    fun optimize module = let
          in
            module
          end

    val optimize = BasicControl.mkKeepPassSimple {
	    output = PrintCPS.output,
            ext = "cps",
            passName = "optimize",
            pass = optimize,
            registry = CPSOptControls.registry
	  }

  end
