(* ast-opt-controls.sml
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu/)
 * All rights reserved.
 *
 * AST-optimization controls.
 *)

structure ASTOptControls =
  struct

    val (registry, debug) = BasicControl.newRegistryWithDebug {
	    name = "ast",
	    pri = 2,
	    help = "controls for AST transformation phases"
	  }

  end
