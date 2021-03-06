(* convert-controls.sml
 *
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu/)
 * All rights reserved.
 *
 * BOM to CPS conversion controls.
 *)

structure ConvertControls =
  struct

    val (registry, debug) = BasicControl.newRegistryWithDebug {
	    name = "convert",
	    pri = 6,
	    help = "CPS-conversion controls"
	  }

  end
