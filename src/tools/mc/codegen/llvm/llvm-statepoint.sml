(* llvm-statepoint.sml
 * 
 * COPYRIGHT (c) 2017 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * GC support for stack-based continuations in LLVM
 *)

structure LLVMStatepoint : sig

    (* inserts a call to the given function into the block that
       is compatible with LLVM's GC Statepoints. *)
    val call :  
              { blk : LLVMBuilder.t,
                conv : LLVMBuilder.convention,
                func : LLVMBuilder.instr,
                args : LLVMBuilder.instr list,
                lives : LLVMBuilder.instr list 
              } -> {
                ret : LLVMBuilder.instr,
                relos : LLVMBuilder.instr list
              }
    
    (* retrieves the list of intrinsic functions required by previous calls.
       you should declare these in the module at the end of codegen. *)
    val exportDecls : unit -> LLVMVar.var list

end = struct

    structure LT = LLVMType
    structure LV = LLVMVar
    structure LB = LLVMBuilder

    local
        val intrinsicTbl = AtomTable.mkTable (1000, Fail "statepoint table")
        val find = AtomTable.find intrinsicTbl
        val insert = AtomTable.insert intrinsicTbl 
    in
        fun getStatepointVar funTy = let
            val name = "llvm.experimental.gc.statepoint." ^ LT.mangledNameOf funTy
            val asAtom = Atom.atom name
        in
            (case find asAtom
              of SOME lv => lv
               | NONE => let
                    val ty = LT.mkPtr(LT.mkVFunc [
                        LT.tokenTy,
                        LT.i64,
                        LT.i32,
                        funTy,
                        LT.i32,
                        LT.i32
                    ])
                    val lv = LV.newWithKind(name, LV.VK_Global true, ty)
               in
                    insert (asAtom, lv);
                    lv
               end
            (* esac *))
        end (* end getStatepointVar *)
        
        fun getResultVar retTy = let
            val name = "llvm.experimental.gc.result." ^ LT.mangledNameOf retTy
            val asAtom = Atom.atom name
        in
            (case find asAtom
              of SOME lv => lv
               | NONE => let
                    val ty = LT.mkPtr(LT.mkFunc [
                        retTy,
                        LT.tokenTy
                    ])
                    val lv = LV.newWithKind(name, LV.VK_Global true, ty)
               in
                    insert (asAtom, lv);
                    lv
               end
            (* esac *))
        end (* end getResultVar *)
        
        fun getRelocateVar varTy = let
            val name = "llvm.experimental.gc.relocate." ^ LT.mangledNameOf varTy
            val asAtom = Atom.atom name
        in
            (case find asAtom
              of SOME lv => lv
               | NONE => let
                    val ty = LT.mkPtr(LT.mkFunc [
                        varTy,
                        LT.tokenTy,
                        LT.i32,
                        LT.i32
                    ])
                    val lv = LV.newWithKind(name, LV.VK_Global true, ty)
               in
                    insert (asAtom, lv);
                    lv
               end
            (* esac *))
        end (* end getRelocateVar *)
        
        fun exportDecls () = AtomTable.listItems intrinsicTbl
        
    end (* end local *)

    (* TODO:
        - actually emit the calls & relocations.
    *)

    fun call (x as {blk, conv, func, args, lives}) = let
            val (token, reloIdx) = doCall x
        in
            raise Fail "implement me"
        end
        
    and doCall {blk, conv, func, args, lives} = let
        val funTy = LB.toTy func
        val SOME arity = LT.arityOf funTy
        val spPrefix = [
            LB.iconst LT.i64 0,         (* id *)
            LB.iconst LT.i32 0,         (* num patch bytes *)
            func,
            LB.iconst LT.i64 arity,
            LB.iconst LT.i64 0          (* flags *)
            ] @ args @ [
            LB.iconst LT.i64 0,         (* num transition args *)
            LB.iconst LT.i64 0          (* num deopt args *)
            ]
            
        val liveStartIdx = List.length spPrefix
        val spArgs = spPrefix @ lives
        val intrinsic = LB.fromV(getStatepointVar funTy)
    in
        (LB.callAs blk conv (intrinsic, Vector.fromList spArgs), liveStartIdx)
    end

end (* LLVMStatepoint *)
