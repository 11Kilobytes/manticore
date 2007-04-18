(* ast.sml
 *
 * COPYRIGHT (c) 2007 John Reppy (http://www.cs.uchicago.edu/~jhr)
 * All rights reserved.
 *
 * Based on CMSC 22610 Sample code (Winter 2007)
 *)

structure AST =
  struct

    datatype ty_scheme = datatype Types.ty_scheme
    datatype ty = datatype Types.ty
    datatype tyvar = datatype Types.tyvar
    datatype dcon = datatype Types.dcon

    datatype exp
      = LetExp of binding * exp
      | IfExp of (exp * exp * exp)
      | CaseExp of (exp * (pat * exp) list)
      | TyApplyExp of (exp * ty list)	(* instantiation of polymorphic expression *)
      | ApplyExp of exp * exp
      | TupleExp of exp list
      | ConstExp of const
      | VarExp of var
      | SeqExp of (exp * exp)

    and binding
      = ValBind of pat * exp
      | FunBind of lambda list

    and lambda = FB of (var * tyvar list * var * exp)

    and pat
      = ConPat of dcon * ty list * var list	(* data-constructor application *)
      | TuplePat of var list
      | VarPat of var
      | ConstPat of const

    and const
      = DConst of dcon
      | IConst of IntInf.int
      | SConst of string

    and var_kind
      = VK_None
      | VK_Pat			(* bound in a pattern *)
      | VK_Fun			(* bound to a function *)
      | VK_Prim			(* builtin function or operator *)

    withtype var = (var_kind, ty_scheme) VarRep.var_rep

    fun varKindToString VK_None = "None"
      | varKindToString VK_Pat = "Pat"
      | varKindToString VK_Fun = "Fun"
      | varKindToString VK_Prim = "Prim"

    type module = exp

  end
