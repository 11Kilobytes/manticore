(* manticore-pseudo-ops-fn.sml
 * 
 * COPYRIGHT (c) 2007 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * MLRISC pseudo ops needed for code generation.
 *)

functor ManticorePseudoOpsFn (
    structure P : PSEUDO_OPS_BASIS
    structure Spec : TARGET_SPEC
  ) : MANTICORE_PSEUDO_OPS = struct
  
    structure P = P
    structure PTy = PseudoOpsBasisTyp
  
    type pseudo_op_ext = unit
    type pseudo_op = unit P.pseudo_op
  
    fun log2 i = let
	  fun lg (0w1, n) = n
	    | lg (i, n) = lg(Word.>>(i, 0w1), n+1)
	  in
	    lg (Word.fromInt i, 0)
	  end
  
    val ty = (IntInf.toInt Spec.ABI.wordSzB) * 8
  
    datatype int_size = I8 | I16 | I32 | I64 | Iptr
	    
    fun intSzToSz I8 = 8
      | intSzToSz I16 = 16
      | intSzToSz I32 = 32
      | intSzToSz I64 = 64
      | intSzToSz Iptr = ty
			 
    val maxAlign = Int.max (IntInf.toInt Spec.ABI.wordAlignB, 
			    IntInf.toInt Spec.ABI.extendedAlignB)
  
    val text : pseudo_op = PTy.TEXT
    fun global lab = PTy.EXPORT [lab]
    fun float (ty, flts) = PTy.FLOAT{sz = ty, f = map FloatLit.toString flts}
    val asciz = PTy.ASCIIZ
    val rodata : pseudo_op = PTy.DATA_READ_ONLY
    val alignData : pseudo_op = PTy.ALIGN_SZ maxAlign
    val alignCode : pseudo_op = PTy.ALIGN_LABEL
    val alignEntry : pseudo_op = PTy.ALIGN_ENTRY
    fun int (sz, ints) = PTy.INT{sz = intSzToSz sz, i = List.map P.T.LI ints}
  
    structure Client =
      struct
	structure AsmPseudoOps = P
	type pseudo_op = pseudo_op_ext
			 
	fun toString () = ""
  
	fun emitValue _ = raise Fail "todo"
	fun sizeOf _ = raise Fail "todo"
	fun adjustLabels _ = raise Fail "todo"
      end (* Client *)
  
    structure PseudoOps = PseudoOps (structure Client = Client)
  
  end (* ManticorePseudoOpsFn *)
