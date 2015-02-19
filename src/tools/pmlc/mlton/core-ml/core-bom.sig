(* This module corresponds to CoreML -- it is a typed counterpart to
AstBOM, like CoreML is a typed counterpart to Ast. *)

signature CORE_BOM_STRUCTS =
  sig
    structure Ast: AST
  end

signature CORE_BOM =
  sig
    include CORE_BOM_STRUCTS

    structure BOM: AST_BOM sharing BOM = Ast.BOM

    (* For now, we copy over the structures we had from ast-bom, but
    leave their signatures blank. They can be filled in as needed,
    reducing cruft *)

    structure HLOpId: sig
    end

    structure Attr: sig
      type t

      val fromAst: BOM.Attrs.t -> t list
      val flattenFromAst: BOM.Attrs.t option -> t list
    end

    structure TyParam: sig
      type t

      val fromAst: BOM.TyParam.t -> t
      val hash: t -> int
      val name: t -> string
      val compare: t * t -> order
    end

    (* structure HLOpQId: sig *)
    (* end *)

    (* structure SymbolicId: sig *)
    (* end *)

    structure BOMId: sig
      type t

      val fromAst: BOM.BOMId.t -> t
      val fromVid: Ast.Vid.t -> t
      val fromLongvid: Ast.Longvid.t -> t
      val fromLongtycon: Ast.Longtycon.t -> t
      val toString: t -> string
      val bogus: t
    end

    (* structure LongTyId: sig *)
    (*   type t *)

    (*   val fromAst: BOM.LongTyId.t -> t *)
    (*   val toString: t -> string *)
    (*   val hasQualifier: t -> bool *)
    (*   val truncate: t -> BOMId.t *)
    (* end *)


    (* structure LongValueId: sig *)
    (*   type t *)

    (*   val fromAst: BOM.LongValueId.t -> t *)
    (*   val toString: t -> string *)
    (*   val hasQualifier: t -> bool *)
    (*   val truncate: t -> BOMId.t *)
    (* end *)

    (* structure LongConId: sig *)
    (*   type t *)

    (*   val fromAst: BOM.LongConId.t -> t *)
    (*   val toString: t -> string *)
    (*   val hasQualifier: t -> bool *)
    (*   val truncate: t -> BOMId.t *)
    (* end *)

    structure ModuleId: sig
      type t

      val compare: t * t -> order
      val fromBOMId: BOM.BOMId.t -> t
      val toString: t -> string
      val toBOMId: t -> BOMId.t
      val bogus: t
    end


    structure TyId: sig
      datatype t
        = BOMTy of BOMId.t
        | QBOMTy of ModuleId.t * BOMId.t

      val fromBOMId: BOM.BOMId.t -> t
      val fromBOMId': BOMId.t -> t
      val fromLongId: BOM.LongId.t -> t
      (* val fromLongTyId: BOM.LongTyId.t -> t *)

      val maybeQualify: t * ModuleId.t -> t

      val toString: t -> string
      val compare: t * t -> order
    end

    structure ValId : sig
      datatype t
        = BOMVal of BOMId.t
        | QBOMVal of ModuleId.t * BOMId.t

      val fromBOMId: BOM.BOMId.t -> t
      val fromBOMId': BOMId.t -> t
      val fromLongId: BOM.LongId.t -> t
      (* val fromLongConId: BOM.LongConId.t -> t *)

      (* Add the given qualifier only if it doesn't yet have one *)
      val maybeQualify: t * ModuleId.t -> t

      val toString: t -> string
      val compare: t * t -> order

      val error: t
    end

    structure RawTy: sig
      datatype t = datatype RawTypes.raw_ty

      val fromAst: BOM.RawTy.t -> t
    end

    datatype field_t
      = Immutable of IntInf.int * type_t
      | Mutable of IntInf.int * type_t
    and type_t
      = Param of TyParam.t
      | TyCon of {
          con: tycon_t,
          args: type_t list
        }
      | Con of {
          dom: type_t,
          rng: type_t
        }
      | Record of field_t list
      | Tuple of (bool * type_t) list
      | Fun of {
          dom: type_t list,
          cont: type_t list,
          rng: type_t list
        }
      | Any
      | VProc
      | Cont of type_t list
      | Addr of type_t
      | Raw of RawTy.t
      | Error
    and dataconsdef_t
      = ConsDef of BOMId.t * type_t option
    and tycon_t
      = TyC of {
          id: TyId.t,
          definition: dataconsdef_t list ref,
          params: TyParam.t list
      }

    structure Field: sig
      datatype t = datatype field_t

      val index: t -> IntInf.int
      val bogus: t
    end

    structure DataConsDef: sig
      datatype t = datatype dataconsdef_t

      val arity: t -> int
      val error: t
    end

    structure BOMType: sig
      datatype t = datatype type_t

      val arity: t -> int
      val applyArg: t * TyParam.t * t -> t
      val applyArgs: t * (TyParam.t * t) list -> t
      val applyArgs': t * TyParam.t list * t list -> t option
      val uniqueTyParams: t -> TyParam.t list

	    (* equality that considers Any to be equal to anything *)
      val equal: t * t -> bool
      val equals: t list * t list -> bool
      val equal': t * t -> t option
      val equals': t list * t list -> t list option

	    (* equality that holds iff two types are identical *)
	    val strictEqual: t * t -> bool
	    val strictEqual': t * t -> t option

      val isCon: t -> t option
      val isFun: t -> t option
      val isCont: t -> t option

      val unit: t
	    (* val wrapTuple: t list -> t *)

    end

    structure TyCon: sig
      (* TODO: this should have a uid *)
      datatype t = datatype tycon_t

      val toBOMTy: t -> BOMType.t
      val arity: t -> int
      val applyToArgs: t * BOMType.t list -> BOMType.t option
      val applyToArgs': t * BOMType.t vector -> BOMType.t option
    end

    structure DataTypeDef: sig
      type t
    end

    structure CArgTy: sig
      datatype t
        = Raw of RawTy.t
        | VoidPointer

      val fromAst: BOM.CArgTy.t -> t
    end

    structure CReturnTy: sig
      datatype t
        = CArg of CArgTy.t
        | Void

      val fromAst: BOM.CReturnTy.t -> t
    end

    (* structure VarPat: sig *)
    (* end *)

    structure Literal: sig
      type t
      datatype node
        = Int of IntInf.int
        | Float of real
        | String of string
        | NullVP

      val new: node * BOMType.t -> t
      val typeOf: t -> BOMType.t
      val valOf: t -> node
    end

    structure Val: sig
      type t

      val typeOf: t -> BOMType.t
      val idOf: t -> ValId.t
      val stampOf: t -> Stamp.stamp

      val compare: t * t -> order
      val same: t * t -> bool

      (* val hasId: t * ValId.t -> bool *)

      val new: ValId.t * BOMType.t * TyParam.t list -> t
      (* val new: BOMType.t * TyParam.t list -> t *)

      val applyToArgs: t * BOMType.t list -> t option

      val error: t
    end

    structure FunDef: sig
      type exp

      datatype t
        = Def of Attr.t list * Val.t * Val.t list * Val.t list * BOMType.t list
            * exp
    end

    structure SimpleExp: sig
      type t

      datatype node
        = PrimOp of t Prim.prim
        | HostVproc
        | VpLoad of IntInf.int * t
        | VpAddr of IntInf.int * t
        | VpStore of IntInf.int * t * t
        | AllocId of Val.t * t
        (* FIXME: alloc <type> form *)
        | RecAccess of IntInf.int * t * t option
        | Promote of t
        | TypeCast of BOMType.t * t
        | Lit of Literal.t
        | MLString of IntInf.int vector
        | Val of Val.t

        val new: node * BOMType.t -> t
        val typeOf: t -> BOMType.t
        val node: t -> node
		    val dest: t -> node * BOMType.t

		    (* val newWithType: (t -> node) * t -> t *)

		    val error: t
    end

    structure CaseRule: sig
      type exp

      datatype t
        = LongRule of Val.t * Val.t list * exp
        | LiteralRule of Literal.t * exp
        | DefaultRule of Val.t * exp

      val returnTy: t -> BOMType.t list
    end

    structure TyCaseRule: sig
      type exp

      datatype t
        = TyRule of BOMType.t * exp
        | Default of exp

      val returnTy: t -> BOMType.t list
    end



    structure PrimOp: sig
      include PRIM_TY

      type arg = SimpleExp.t

      (* primitive operators *)
      type t = arg Prim.prim

      (* primitive conditionals *)
      type cond = arg Prim.cond

      val returnTy: t -> BOMType.t

      (* SOME if the application is good (correct number of args of
       the correct type to a real primop), otherwise, NONE *)
      val applyOp: BOM.PrimOp.t * arg list -> t option
      val applyCond: BOM.PrimOp.t * arg list -> cond option
    end

    structure Exp: sig
      type t

      datatype node
        = Let of Val.t list * rhs * t
        | FunExp of FunDef.t list * t
        | ContExp of Val.t * Val.t list * t * t
        | If of PrimOp.cond * t * t
        | Do of SimpleExp.t * t
        | Case of SimpleExp.t * CaseRule.t list
        | Typecase of TyParam.t * TyCaseRule.t list
        | Apply of Val.t * SimpleExp.t list * SimpleExp.t list
        | Throw of Val.t * SimpleExp.t list
        | Return of SimpleExp.t list
      and rhs
        = Composite of t
        | Simple of SimpleExp.t

      val new: node * BOMType.t list -> t
      val typeOf: t -> BOMType.t list
      val node: t -> node
		  val dest: t -> node * BOMType.t list

		  val error: t
    end

    structure HLOp: sig
      (* collapse HLOp(Q)Id together here *)
    end

    structure Definition: sig
      datatype t
        = Fun of FunDef.t list
        | HLOp of Attr.t list * ValId.t * Exp.t
        | Import of BOMType.t
        | Extern of CReturnTy.t * Val.t * CArgTy.t list * Attr.t list
              (* TODO: datatypes *)
    end

    (* structure Decs : sig *)
    (*   datatype t = T of Definition.t list *)

    (*   val empty: t *)
    (* end *)
    (* sharing type Exp.primOp = PrimOp.t *)
    sharing type CaseRule.exp = TyCaseRule.exp = FunDef.exp = Exp.t
end