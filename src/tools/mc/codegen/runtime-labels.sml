(* runtime-labels.sml
 * 
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Fixed labels to interface with the outside world.
 *)

structure RuntimeLabels = struct

  local val global = Label.global
  in
    val initGC = global "asm_init_gc"
  end (* local *)

end (* RuntimeLabels *)
