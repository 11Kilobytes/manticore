(* eff-sfs-closure.sml
 *
 * COPYRIGHT (c) The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * This transformation converts from a CPS IR with free variables to a
 * version of the CPS where closures are explicit and each function has
 * no free variables (known as CLO in the Shao/Appel work).
 *
 *       "Efficient and Safe-for-Space Closure Conversion
 *       Zhong Shao and Andrew W. Appel
 *       TOPLAS, V 22, Nr. 1, January 2000, pp 129-161.
 *
 * Note that we only use the portion of this work that determins which
 * FVs should be turned into parameters, based on the number of available
 * registers, including callee-save registers for continuations.
 * Then, we rely on simple flat closure conversion to handle both unknown
 * functions (as in the SSCC work) and for known functions that have too
 * many FVs (different from the SSCC work, which uses linked closures).
 *)

functor ClosureConvertFn (Target : TARGET_SPEC) : sig

    val transform : CPS.module -> CPS.module

  end = struct

    structure PPt = ProgPt
    structure C = CPS
    structure CV = C.Var
    structure VMap = CV.Map
    structure VSet = CV.Set
    structure U = CPSUtil
    structure CTy = CPSTy
    structure CFA = CFACPS
    structure ST = Stats

  (***** Statistics *****)
    val cntFunsClosed		= ST.newCounter "clos:num-funs-closed"
    val cntFunsPartial		= ST.newCounter "clos:num-funs-partially-closed"

  (***** controls ******)
    val enableClosureConversion = ref false
    val closureConversionDebug = ref true

    val nCalleeSaveRegs = 3

    val () = List.app (fn ctl => ControlRegistry.register ClosureControls.registry {
              ctl = Controls.stringControl ControlUtil.Cvt.bool ctl,
              envName = NONE
            }) [
              Controls.control {
                  ctl = enableClosureConversion,
                  name = "closure-convert",
                  pri = [0, 1],
                  obscurity = 0,
                  help = "enable Shao/Appel Eff/SfS closure conversion"
                },
              Controls.control {
                  ctl = closureConversionDebug,
                  name = "closure-convert-debug",
                  pri = [0, 1],
                  obscurity = 0,
                  help = "debug closure conversion "
                  }
            ]

    (* The stage number is:
     * 1 for the outermost function
     * 1+ SN(g) if f is a function and g encloses f
     * 1+ max{SN(g) | g \in CFA.callersOf k} if k is a continuation
     *)
    local
        val {setFn, getFn=getSN, ...} =
            CV.newProp (fn f => NONE)
    in
    fun setSN(f, i : int) = setFn(f, SOME i)
    val getSN = getSN
    end

    fun getSafe f = (CV.useCount f = CV.appCntOf f andalso
                         case CFACPS.callersOf f of CFACPS.Known _ => true | CFACPS.Unknown => false)
                      
    fun isCont f =
        case CV.typeOf f
         of CTy.T_Cont _ => true
          | _ => false

    (*
     * Any continuation that escapes through any location other than the
     * retK is considered CALLEE_SAVE. This distinction will roughly correspond to
     * partitioning the continuations into user and CPS-introduced continuations.
     *
     * KNOWN corresponds to the SML/NJ's known: appCnt=useCount and all call sites are
     * known. It will be safely modified.
     *
     * All other continuations are ESCAPING, either because they have some CFA-unknown callers
     *)
    datatype contKind = ESCAPING | KNOWN | CALLEE_SAVE
    local
        val {setFn, getFn=getContKind, ...} =
            CV.newProp (fn f => (case CV.kindOf f of C.VK_Cont _ => ()
                                                   | _ => raise Fail (concat[CV.toString f,
                                                                             " is not a VK_Cont, so its contKind must be set.\n"]);
                                 case (CV.useCount f = CV.appCntOf f,
                                       case CFACPS.callersOf f of CFACPS.Known _ => true | CFACPS.Unknown => false)
                                  of (true, true) => KNOWN
                                   | (_, false) => ESCAPING (* called from somewhere that we can't change a signature *)
                                   | (false, true) => CALLEE_SAVE))
    in
    val getContKind = getContKind
    fun setContKind (v,k) = (print (concat[CV.toString v, " set to contKind: ",
                                           case k
                                            of ESCAPING => "escaping\n"
                                             | KNOWN => "known\n"
                                             | CALLEE_SAVE => "callee-save\n"]); setFn (v,k))
    end


    (* The FV property maps from a function to a Varmap from the (raw) free variables
     * to their first and last used times (SNs). The initial values are set to
     * the current function's SN (else they would not be free!), but the last used
     * time will be updated during the analysis of the static nesting of the
     * functions.
     *)
    val {setFn=setFVMap, getFn=getFVMap, ...} =
        CV.newProp (fn f => let
                           val fvSet = FreeVars.envOfFun f
                           val fut = valOf (getSN f)
                       in
                           VSet.foldl (fn (x, m) => VMap.insert (m, x, (fut, fut)))
                           VMap.empty fvSet                           
                       end)

    (* The slot count is the number of available registers to use for extra closure
     * parameters.
     * Initialize:
     * - 1 for any lambda with unknown call sites
     * - otherwise, (Target.availRegs - #params)
     *
     * Loop to discover the final count per section 4.3
     *)
    val {setFn=setSlot, getFn=getSlot, ...} =
        CV.newProp (fn f =>
                       if not(getSafe f)
                       then 1
                       else Target.availRegs - (
                            case CV.kindOf f
                             of C.VK_Fun (C.FB{params, rets,...}) =>
                                (List.length params + List.length rets + (List.foldl (fn (r,i) =>
                                                                                         case (getContKind r)
                                                                                          of CALLEE_SAVE => i + nCalleeSaveRegs
                                                                                           | _ => i) 0 rets))
                              | C.VK_Cont (C.FB{params, rets,...}) =>
                                (List.length params + List.length rets + nCalleeSaveRegs)
                              | k => raise Fail (concat["Variable: ",
                                                        CV.toString f,
                                                        " cannot have slots because it is of kind: ",
                                                        C.varKindToString k])))

    fun setSNs (CPS.MODULE{body, ...}) = let
          fun doLambda (CPS.FB{f, params, rets, body}, i) = (
              setSN (f, i);
              doExp (body, i))
          and doCont (CPS.FB{f, params, rets, body}, i) = f::doExp (body, i)
          and doExp (CPS.Exp(_, e), i) = (case e 
                 of CPS.Let(xs, _, e) => (doExp (e, i))
                  | CPS.Fun(fbs, e) => (List.foldl (fn (f,l) => l@doLambda (f,i+1)) [] fbs) @ doExp (e, i)
                  | CPS.Cont(fb, e) => (doCont (fb, i+1) @ doExp (e, i))
                  | CPS.If(_, e1, e2) => (doExp (e1, i) @ doExp (e2, i))
                  | CPS.Switch(_, cases, dflt) => (
		      (List.foldl (fn (c,l) => l@doExp(#2 c, i)) [] cases) @
                      (case dflt of NONE => []
                                  | SOME e => doExp (e, i)))
                  | CPS.Apply _ => []
                  | CPS.Throw _ => []
                (* end case *))
          val conts = doLambda (body, 1)
          fun handleConts ([], [], i) = ()
            | handleConts ([], later, i) = let
              in
                  (*
                   * The statement about CPS call graphs in 4.1/4.2 is a bit tricky for us.
                   * Our continutations can take multiple continuations as arguments, which
                   * means that while we cannot have statically mutually recursive continuations,
                   * dynamically they can be (and often are!).
                   *
                   * This case implements a somewhat-arbitrary tie-breaker. If there is a set
                   * of continuations we are not making progress on, just set the stage number
                   * of the first one in the list based on the knowledge we do have so far and then
                   * continue with the rest.
                   *)
                  if (List.length later = i)
                  then let
                          val first::rest = later
                          val CFACPS.Known(s) = CFACPS.callersOf first
                      in
                          setSN (first, 1 + VSet.foldl (fn (f, i) => Int.max (i,
                                                                              case getSN f
                                                                               of NONE => 0
                                                                                | SOME i' => i'))
                                        0 s);
                          handleConts (List.rev rest, [], i-1)
                      end
                  else handleConts (List.rev later, [], List.length later)
              end
            | handleConts (k::conts, later, i) = let
                  val callers = CFACPS.callersOf k
              in
                  case callers
                   of CFACPS.Unknown => (setSN(k, 1);
                                         handleConts (conts, later, i))
                    | CFACPS.Known s => let
                          val f = VSet.find (fn f => not (isSome (getSN f))) s
                      in
                      if not (isSome (f))
                      then (setSN(k, 1 + VSet.foldl (fn (f,i) => Int.max (i, valOf (getSN f)))
                                                    0 s);
                            handleConts (conts, later, i))
                      else (handleConts (conts, k::later, i))
                      end
              end
    in
        handleConts (conts, [], 0)
    end

    (* Also add fut/lut properties to variables, per function.
     * Need to add an FV->{fut,lut} map to each function variable.
     * a. Do it as a depth-first traversal. At the leaf, all FVs basically have the SN(f) for their fut/lut
     * b. Return the union of the var-maps from the other functions. Collisions get the min(fut) but the max(lut)
     * c. In the intermediate nodes, if the FV is used, fut = SN(f), else fut=lut(union-map)
     *)
    fun updateLUTs (CPS.MODULE{body, ...}) = let
        fun mergeFVMaps (maps) = let
            fun mergeMaps ([], final) = final
              | mergeMaps (m::maps, final) =
                mergeMaps (maps,
                           (VMap.foldli (fn (v, p as (fut, lut), final) =>
                                            case VMap.find (final, v)
                                             of NONE => VMap.insert (final, v, p)
                                              | SOME (fut', lut') =>
                                                VMap.insert (final, v, (Int.min (fut, fut'),
                                                                        Int.max (lut, lut'))))
                                        final m))
        in
            case maps
             of [] => VMap.empty
              | [m] => m
              | m::ms => mergeMaps (ms, m)
        end
        fun doLambda (CPS.FB{f, params, rets, body}) = let
            val childMap = doExp body
            val (newMap, retMap) =
                VMap.foldli (fn (v, p as (fut, lut), (newMap, retMap)) => 
                                case VMap.find (retMap, v)
                                 of NONE => (newMap,
                                             VMap.insert (retMap, v, p))
                                  | SOME (_, lut') => 
                                    if (lut' > lut)
                                    then (VMap.insert (newMap, v, (fut, lut')),
                                          retMap)
                                    else (newMap, retMap))
                            (VMap.empty, childMap) (getFVMap f)
        in
            setFVMap (f, newMap);
            retMap
        end
        and doExp (CPS.Exp(_, e)) = (
            case e 
             of CPS.Let(xs, _, e) => (doExp e)
              | CPS.Fun(fbs, e) => (mergeFVMaps ((doExp e)::(List.map doLambda fbs)))
              | CPS.Cont(fb, e) => (mergeFVMaps([doLambda fb, doExp e]))
              | CPS.If(_, e1, e2) => (mergeFVMaps([doExp e1, doExp e2]))
              | CPS.Switch(_, cases, dflt) => let
                    val caseMaps = List.map (fn c => doExp (#2 c)) cases
                    val l = case dflt of NONE => caseMaps
                                       | SOME e => (doExp e)::caseMaps
                in
                    mergeFVMaps l
                end
              | CPS.Apply _ => VMap.empty
              | CPS.Throw _ => VMap.empty
        (* end case *))
    in
        doLambda body
    end

    fun getSafeFuns (CPS.MODULE{body, ...}) = let
        fun setVarContKind v =
            if isCont v
            then (case CFACPS.valueOf v
                   of a as CFACPS.LAMBDAS(s) => let
                          val target = hd (VSet.listItems s)
                      in
                          print (concat["Because of ", CV.toString target, " "]);
                          setContKind (v, getContKind target)
                      end
                    | cv => (print (concat["CFA value is ", CFACPS.valueToString cv, ", so "]);
                             setContKind (v, ESCAPING)))
            else ()
        fun doLambda (CPS.FB{f, params, rets, body}) = let
            val _ = List.app setVarContKind params
            val _ = List.app setVarContKind rets
        in
            (f::(doExp body))
        end
        and doExp (CPS.Exp(_, e)) = (
            case e 
             of CPS.Let(xs, _, e) => (List.app setVarContKind xs;
                                        doExp e)
              | CPS.Fun(fbs, e) => (doExp e @ (List.foldl (fn (fb,l) => l @ doLambda fb) [] fbs))
              | CPS.Cont(fb, e) => (doLambda fb @ doExp e)
              | CPS.If(_, e1, e2) => (doExp e1 @ doExp e2)
              | CPS.Switch(_, cases, dflt) => let
                    val cases = List.foldl (fn (c,l) => l@doExp (#2 c)) [] cases
                in
                    case dflt of NONE => cases
                               | SOME e => (doExp e)@cases
                end
              | CPS.Apply (_, _, _) => ([])
              | CPS.Throw (_, _) => ([])
        (* end case *))
        val funs = doLambda body
        val funs = List.filter (fn (f) => getSafe f) funs
    in
        funs
    end
                                
    (* Assign the # of slots to functions for their free variables
     * a. Initialize S(f) = max(AVAIL_REG - arg_count(f), 0)  for known, = 1 for escaping
     * b. Iterate S(f) = min ({T(g, f) | g \in V(f)} U {S(f)})
     * c. where T(g, f) = max(1, S(g)- |FV(g)-  FV(f)|)
     * V(f) is all of the callersOf f where f is also free in that function
     * Q: How do I handle that two functions that share a call site also share the number
     * of slots?
     *)
    fun setSlots (funs) = let
        fun updateSlotCount(f) = let
            val fFVs = (FreeVars.envOfFun f)
            val fFVfuns = VSet.filter (fn v => case CV.kindOf v
                                                of C.VK_Cont _ => true (* ? *)
                                                 | C.VK_Fun _ => true
                                                 | _ => false) fFVs
            val CFACPS.Known(fPreds) = CFACPS.callersOf f
            val fFreePreds = VSet.intersection (fPreds, fFVfuns)
            fun T(g) = Int.max (1, (getSlot g) - VSet.numItems (VSet.difference ((FreeVars.envOfFun g),
                                                                          fFVs)))
            and S(f) = VSet.foldl (fn (g, i) => Int.min (i, T(g))) (getSlot f) fFreePreds
            val newCount = S(f)
        in
            if (newCount <> getSlot f)
            then (setSlot (f, newCount); true)
            else false
        end
        fun loop () = let
            val changed = List.foldl (fn (f, b) => b orelse updateSlotCount f) false funs
        in
            if changed
            then loop()
            else ()
        end
    in
        loop()
    end

    (*
     * The params properties list the new parameters for a given SAFE function.
     * It is a VMap from old FV-name to new param-name.
     *)
    local
        val {setFn=setParams, getFn=getParams, ...} =
            CV.newProp (fn f => raise Fail (concat[CV.toString f, " has no params and ", if getSafe f then "is safe" else "is not safe"]))
    in
    val getParams: CV.var -> (CV.var VMap.map) = getParams
    val setParams=setParams
    end

    (*
     * For safe FBs, if the number of FVs is < the number of slots available
     * then, we just add all of those variables as new, additional parameters to the function
     * else, add (slots-1) of those FVs, preferring lowest LUT then lowest FUT
     *
     * For unsafe conts, we add up to the nCalleeSaves of the top-ranked FVs to be added as
     * new parameters for callers to track. Note that they will be passed around as :any,
     * so we must restrict the map to variables of non-raw types.
     *)
    fun computeParams (CPS.MODULE{body, ...}) = let
        fun findBest (n, map) = let
            fun firstBigger ((_, (fut1, lut1)), (_, (fut2, lut2))) =
                (lut1 > lut2) orelse ((lut1 = lut2) andalso (fut1 > fut2))
            val sorted = ListMergeSort.sort firstBigger (VMap.listItemsi map)
        in
            List.map (fn (p, _) => p) (List.take (sorted, n))
        end
        fun computeParam (f, map, i) = let
            val map = getFVMap f
            val i = getSlot f
        in
            case VMap.numItems map
             of 0 => (setParams (f, VMap.empty))
              | n => (if n <= i
                      then (ST.tick cntFunsClosed;
                            setParams (f, 
                                       VMap.foldli (fn (p, _, m) => VMap.insert (m, p, CV.copy p))
                                       VMap.empty map))
                      else (let
                                val _ = ST.tick cntFunsPartial
                                val toCopy = findBest (i-1, map)
                            in
                                setParams (f, 
                                           List.foldl (fn (p, m) => VMap.insert (m, p, CV.copy p))
                                                       VMap.empty toCopy)
                            end))
        end
        fun doLambda (fb as CPS.FB{f, params, rets, body}) = (
            if getSafe f
            then computeParam (f, getFVMap f, getSlot f)
            else (if isCont f
                  then let
                          val map = getFVMap f
                          val map = VMap.filteri (fn (v,_) => case CPSTyUtil.kindOf (CV.typeOf v)
                                                               of CTy.K_RAW => false
                                                                | _ => true) map
                      in
                          computeParam (f, map, nCalleeSaveRegs)
                      end
                  else ());
            (doExp body))
        and doExp (CPS.Exp(_, e)) = (
            case e 
             of CPS.Let(xs, _, e) => (doExp e)
              | CPS.Fun(fbs, e) => (List.app doLambda fbs; doExp e )
              | CPS.Cont(fb, e) => (doLambda fb ; doExp e)
              | CPS.If(_, e1, e2) => (doExp e1 ; doExp e2)
              | CPS.Switch(_, cases, dflt) => (
                List.app (fn c => doExp (#2 c)) cases;
                Option.app doExp dflt)
              | CPS.Apply _ => ()
              | CPS.Throw _ => ()
        (* end case *))
    in
        doLambda body
    end

    (*
     * We can remove a function from the FV list if:
     * 1) it is a function name
     * 2) it is safe
     * 3) all of its params have been passed in
     *)
    fun reduceParams funs = let
        fun isEligible f =
            case (CV.kindOf f, getSafe f)
             of (C.VK_Fun _, true) => true
              | (C.VK_Cont _, true) => true
              | _ => false
        fun reduceParam f = let
            val pset = VMap.foldli (fn (v,_,s) => VSet.add(s,v)) VSet.empty (getParams f)
            val (params,funs) = VSet.foldl (fn (f, (ps,fs)) => if isEligible f
                                                               then (ps, VSet.add (fs,f))
                                                               else (VSet.add (ps,f), fs))
                                           (VSet.empty, VSet.empty) pset
            val keepFuns = VSet.foldl (fn (v,s) => if VSet.isSubset (FreeVars.envOfFun v, pset)
                                                   then s
                                                   else (VSet.add (s,v)))
                           VSet.empty funs
            val pset = VSet.union (params, keepFuns)
            fun mustKeep (f,_) = VSet.member (pset, f)
        in
            setParams (f, VMap.filteri mustKeep (getParams f))
        end
    in
        List.app reduceParam funs
    end

    (*
     * The params properties list the new parameters for a given SAFE function.
     * It is a VMap from old FV-name to new param-name.
     *)
    local
        val {setFn=setCalleeParams, getFn=getCalleeParams, ...} =
            CV.newProp (fn f => raise Fail (concat[CV.toString f, " has no callee-save params associated with it."]))
    in
    val getCalleeParams: CV.var -> (CV.var list) = getCalleeParams
    val setCalleeParams=setCalleeParams
    end

    (*
     * Simply adds the new parameters to the function.
     * Note that they retain their old names because this allows the type-based
     * iterative fixup to correctly globally update all associated types without
     * performing CFA a second time to give us enough info to fix them up directly.
     *
     * Also, notice the callee-save register additions. They are made in two places:
     * - All _Fun types get (length rets)*nCalleeSaveRegs additional params of type :any
     * - All _Cont types that are NOT safe get three additional params, again of
     * type :any
     * These conts are restricted to just the ones that are non-escaping.
     *)
    fun addParams (C.MODULE{name,externs,body}) = let
        fun convertFB (C.FB{f, params, rets, body}) = let
            fun genCalleeSaveParams ret = let
                fun genCalleeSaveParam 0 = []
                  | genCalleeSaveParam i = ((CV.new (CV.nameOf ret ^ Int.toString i,
                                                     CTy.T_Any))::(genCalleeSaveParam (i-1)))
                val nParams = (case getContKind ret
                                of CALLEE_SAVE => (print (concat[CV.toString ret, " is CS\n"]); nCalleeSaveRegs)
                                 | ESCAPING => (print (concat[CV.toString ret, " is ESCAPING!\n"]); 0)
                                 | KNOWN => (print (concat[CV.toString ret, " is KNOWN!\n"]); 0))
                val _ = print (concat[CV.toString ret, " callee-saves: ", Int.toString nParams, "\n"])
                val params = genCalleeSaveParam nParams
                val _ = case CV.typeOf ret
                         of CTy.T_Cont orig => CV.setType (ret, CTy.T_Cont (orig @ List.map (fn v => CV.typeOf v) params))
                          | x => raise Fail (concat["Non-cont type - ", CV.toString ret,
                                                    ":", CPSTyUtil.toString (CV.typeOf ret)])

                val _ = setCalleeParams (ret, params)
            in
                params
            end
            fun genContCalleeSaveParams () = let
                val newArgsMap = getParams f
                val oldNewList = VMap.listItemsi newArgsMap
                val newParams = List.map (fn (p, _) => p) oldNewList
                val nParamsMissing = nCalleeSaveRegs - List.length newParams
            in
                case Int.compare (nParamsMissing, 0)
                 of EQUAL => newParams
                  | GREATER => newParams @ List.tabulate (nParamsMissing, (fn _ => CV.new ("ignoredCalleeSave", CTy.T_Any)))
                  | LESS => raise Fail (concat["Continuation ", CV.toString f, " is callee-save but has too many new params: ",
                                               String.concat(List.map CV.toString newParams)])
            end
            val calleeSaveParams = (
                case CV.typeOf f
                 of CTy.T_Fun _ => List.concat (List.map genCalleeSaveParams rets)
                  | CTy.T_Cont _ => (case getContKind f of CALLEE_SAVE => genContCalleeSaveParams() | _ => [])
                  | x => raise Fail (concat["Non-function type - ", CV.toString f,
                                            ":", CPSTyUtil.toString (CV.typeOf f)]))
        in
            if getSafe f
            then let
                    val newArgsMap = getParams f
                    val oldNewList = VMap.listItemsi newArgsMap
                    val newParams = List.map (fn (p, _) => p) oldNewList
                    val params' = params @ newParams @ calleeSaveParams
                    val body = convertExp body
                    val origType = CV.typeOf f
                    val newType = case origType
                                   of CTy.T_Fun (_, retTys) =>
                                      CTy.T_Fun(List.map CV.typeOf params', retTys)
                                    | CTy.T_Cont (_) => 
                                      CTy.T_Cont(List.map CV.typeOf params')
                                    | x => raise Fail (concat["Non-function type - ", CV.toString f,
                                                              ":", CPSTyUtil.toString (CV.typeOf f)])
                    val _ = CV.setType (f, newType)
                    val _ = if !closureConversionDebug
                            then print (concat[CV.toString f, " safe fun added params\nOrig: ",
                                               CPSTyUtil.toString origType, "\nNew : ",
                                               CPSTyUtil.toString newType, "\nParams   :",
                                               String.concatWith "," (List.map CV.toString params), "\nNewParams :",
                                               String.concatWith "," (List.map CV.toString newParams), "\nCalleeSaveP:",
                                               String.concatWith "," (List.map CV.toString calleeSaveParams), "\nMap:",
                                               String.concatWith "," (List.map CV.toString (List.map (fn (_, p) => p) oldNewList)),
                                               "\n"])
                            else ()
                    val _  = List.app (fn p => (List.app (fn p' => if CV.same(p, p')
                                                                   then raise Fail (concat["In ", CV.toString f, " double-adding ",
                                                                                           CV.toString p])
                                                                   else ()) newParams)) params
                in
                    C.FB{f=f, params=params', rets=rets, body=body}
                end
            else let
                    val params = params @ calleeSaveParams
                    val body = convertExp body
                    val origType = CV.typeOf f
                    val newType = case origType
                                   of CTy.T_Fun (_, retTys) =>
                                      CTy.T_Fun(List.map CV.typeOf params, retTys)
                                    | CTy.T_Cont (_) => 
                                      CTy.T_Cont(List.map CV.typeOf params)
                                    | x => raise Fail (concat["Non-function type - ", CV.toString f,
                                                              ":", CPSTyUtil.toString (CV.typeOf f)])
                    val _ = CV.setType (f, newType)
                    val _ = if !closureConversionDebug
                            then print (concat[CV.toString f, " non-safe fun added params\nOrig: ",
                                               CPSTyUtil.toString origType, "\nNew : ",
                                               CPSTyUtil.toString newType, "\nParams   :",
                                               String.concatWith "," (List.map CV.toString params), "\n"])
                            else ()
                in
                    C.FB{f=f, params=params, rets=rets, body=body}
                end
        end
        and convertExp (C.Exp(ppt,t)) = (
            case t
             of C.Let (lhs, rhs, exp) => C.mkLet(lhs, rhs,
                                                 convertExp exp)
              | C.Fun (lambdas, exp) => (C.mkFun (List.map (fn fb => convertFB (fb)) lambdas, convertExp (exp)))
              | C.Cont (lambda, exp) => (C.mkCont (convertFB lambda, convertExp (exp)))
              | C.If (cond, e1, e2) => C.mkIf(cond,
		                              convertExp(e1),
		                              convertExp(e2))
              | C.Switch(x, cases, dflt) => 
	        C.mkSwitch (x,
		            List.map (fn (l, e) => (l, convertExp(e))) cases,
		            Option.map (fn e => convertExp(e)) dflt)
              | e => C.mkExp e)
    in
        C.MODULE{
        name=name, externs=externs,
        body = convertFB body}
    end

    fun getSafeCallTarget' f =
        case CFACPS.valueOf f
         of a as CFACPS.LAMBDAS(s) => let
                    val target = hd (VSet.listItems s)
                in
                    if isCont f orelse VSet.numItems s = 1
                    then SOME(target)
                    else NONE
                end
          | _ => NONE

    fun getSafeCallTarget f =
        case CFACPS.valueOf f
         of a as CFACPS.LAMBDAS(s) => let
                    val target = hd (VSet.listItems s)
                in
                    if VSet.numItems s > 0 andalso getSafe target
                    then (print (concat["GSCT: ", CV.toString f, " => ", CV.toString target, "\n"]); SOME(target))
                    else NONE
                end
          | _ => NONE

    fun fixLet (lhs, rhs) = let
        (* Only return a changed type if it's likely to be different.
         * For many RHS values, it's neither straightforward nor necessary to
         * compute a new type value, as it can't have been changed by the
         * flattening transformation.
         *)
        fun typeOfRHS(C.Var ([v])) = SOME (CV.typeOf v)
          | typeOfRHS(C.Var (vars)) = NONE
          | typeOfRHS(C.Cast (typ, var)) = (* if the cast is or contains a function type,
                                            * we may have updated it in an incompatible way
                                            * for the cast, so just fill in our type.
                                            * This frequently happens around the generated _cast
                                            * for ropes code
                                            *)
            let
                val rhsType = CV.typeOf var
                fun cleanup (CTy.T_Tuple (b, dstTys), CTy.T_Tuple (b', srcTys)) = let
                    val dstLen = List.length dstTys
                    val srcLen = List.length srcTys
                    val (dst', src') = (
                        case Int.compare (dstLen, srcLen)
                         of LESS => (dstTys @ (List.tabulate (srcLen-dstLen, (fn (x) => CTy.T_Any))), srcTys)
                          | EQUAL => (dstTys, srcTys)
                          | GREATER => (dstTys, srcTys @ (List.tabulate (dstLen-srcLen, (fn (x) => CTy.T_Any)))))
                in
                    CTy.T_Tuple (b, ListPair.mapEq cleanup (dst', src'))
                end
                  | cleanup (dst as CTy.T_Fun(_, _), src as CTy.T_Fun (_, _)) =
                    if CPSTyUtil.soundMatch (dst, src)
                    then dst
                    else src
                  | cleanup (dst as CTy.T_Cont(_), src as CTy.T_Cont (_)) =
                    if CPSTyUtil.soundMatch (dst, src)
                    then dst
                    else src
                  | cleanup (dst, _) = dst
                val result = cleanup (typ, rhsType) 
            in
                SOME (result)
            end
          | typeOfRHS(C.Const (_, typ)) = SOME(typ)
          | typeOfRHS(C.Select (i, v)) = (
            (* Select is often used as a pseudo-cast, so only "change" the type if we've 
             * come across a slot that is a function type, which we might have updated.
             *)
            case CV.typeOf v
             of CTy.T_Tuple (_, tys) => (
                case List.nth (tys, i)
                 of newTy as CTy.T_Fun (_, _) => SOME (newTy)
                  | newTy as CTy.T_Cont _ => SOME (newTy)
                  | _ => NONE
                (* end case *))
              | ty => raise Fail (concat [CV.toString v,
                                          " was not of tuple type, was: ",
                                          CPSTyUtil.toString ty])
            (* end case *))
          | typeOfRHS(C.Update (_, _, _)) = NONE
          | typeOfRHS(C.AddrOf (i, v)) = (
            (* Select is often used as a pseudo-cast, so only "change" the type if we've 
             * come across a slot that is a function type, which we might have updated.
             *)
            case CV.typeOf v
             of CTy.T_Tuple (_, tys) => (
                case List.nth (tys, i)
                 of newTy as CTy.T_Fun (_, _) => SOME (CTy.T_Addr(newTy))
                  | newTy as CTy.T_Cont _ => SOME (CTy.T_Addr(newTy))
                  | _ => NONE
                (* end case *))
              | ty => raise Fail (concat [CV.toString v,
                                          " was not of tuple type, was: ",
                                          CPSTyUtil.toString ty])
            (* end case *))
          | typeOfRHS(C.Alloc (CPSTy.T_Tuple(b, tys), vars)) = let
                (*
                 * Types of items stored into an alloc are frequently wrong relative to
                 * how they're going to be used (i.e. a :enum(0) in for a ![any, any]).
                 * Only update function types.
                 *)
                fun chooseType (ty, vTy as CTy.T_Fun(_, _)) = vTy
                  | chooseType (ty, vTy as CTy.T_Cont _) = vTy
                  | chooseType (ty as CTy.T_Tuple(_,tys), vTy as CTy.T_Tuple(b,vTys)) =
                    CTy.T_Tuple(b, ListPair.map chooseType (tys, vTys))
                  | chooseType (ty, _) = ty
            in
                SOME (CPSTy.T_Tuple(b, ListPair.map chooseType (tys, (List.map CV.typeOf vars))))
            end
          | typeOfRHS(C.Alloc (_, vars)) = raise Fail "encountered an alloc that didn't originally have a tuple type."
          | typeOfRHS(C.Promote (v)) = SOME (CV.typeOf v)
          | typeOfRHS(C.Prim (prim)) = NONE (* do I need to do this one? *)
          | typeOfRHS(C.CCall (cfun, _)) = NONE
          | typeOfRHS(C.HostVProc) = NONE
          | typeOfRHS(C.VPLoad (_, _)) = NONE
          | typeOfRHS(C.VPStore (_, _, _)) = NONE
          | typeOfRHS(C.VPAddr (_, _)) = NONE
    in
        (case lhs
          of [v] => (
             case typeOfRHS (rhs)
              (* Even if we got a new type back, if the existing one is equal or more
               * specific, stick with the old one.
               *)
              of SOME(ty) => (if !closureConversionDebug
                              then print (concat["Changing ", CV.toString v,
                                                 " from: ", CPSTyUtil.toString (CV.typeOf v),
                                                 " to: ", CPSTyUtil.toString ty, "\n"])
                              else ();
                              CV.setType (v, ty))
               | NONE => ()
             (* end case *))
           | _ => ()
        (* end case *))
    end

    (* 
     * The function types on all variables that are equivalent to the
     * safe/converted functions need to be fixed up to have the same
     * type as the function now has.
     *
     * Because this change can affect parameters to functions, we need
     * to push these changes through iteratively until the types no longer
     * change.
     * NOTE: this code is a simpler version of the code appearing in
     * signature fixup in cps-opt/arity-raising.
     *)
    fun propagateFunChanges (C.MODULE{body=fb,...}) = let
        val changed = ref false
        fun transformRet ret = (
            case getContKind ret
             of CALLEE_SAVE => (
                case CFACPS.valueOf ret
                 of a as CFACPS.LAMBDAS(s) => let
                        val target = hd (VSet.listItems s)
                        val newType = CV.typeOf target
                    in
                        if CPSTyUtil.equal (CV.typeOf ret, newType)
                        then ()
                        else (print (concat["Changed: ", CV.toString ret, " from ",
                                            CPSTyUtil.toString (CV.typeOf ret), " to ",
                                            CPSTyUtil.toString newType, "\n"]);
                              changed := true;
                              CV.setType (ret, newType))
                    end
                  | _ => raise Fail "blah")
              | KNOWN => transformParam ret
              | _ => ())
        and transformParam param = let
            fun getParamFunType (l, orig) =let
                val lambdas = CPS.Var.Set.listItems l
             in
                case List.length lambdas
                 of 0 => orig
                  | _ => (case getSafeCallTarget' (hd lambdas)
                           of SOME a => CV.typeOf a
                            | NONE => orig)
            end
            fun buildType (CPSTy.T_Tuple (heap, tys), cpsValues) = let
                fun updateSlot (origTy, cpsValue) = (
                    case cpsValue
                     of CFACPS.LAMBDAS(l) => getParamFunType (l, origTy)
                      | CFACPS.TUPLE (values) => buildType (origTy, values)
                      | _ => origTy
                (* end case *))
                val newTys = ListPair.map updateSlot (tys, cpsValues)
            in
                CPSTy.T_Tuple (heap, newTys)
            end
              | buildType (ty, _) = ty
        in
            case CFACPS.valueOf param
             of a as CFACPS.LAMBDAS(l) => let
                    val newType = getParamFunType (l, CV.typeOf param)
                in
                    if CPSTyUtil.equal (CV.typeOf param, newType)
                    then ()
                    else (changed := true;
                          if !closureConversionDebug
                          then print (concat["Changed LAMBDAS(", CFACPS.valueToString a, ") for ",
                                             CV.toString param, " from: ",
                                             CPSTyUtil.toString (CV.typeOf param), " to: ",
                                             CPSTyUtil.toString newType, "\n"])
                          else ();
                          CV.setType (param, newType))
                end

              | CFACPS.TUPLE(values) => let
                    val newType = buildType (CV.typeOf param, values)
                in
                    if CPSTyUtil.equal (CV.typeOf param, newType)
                    then ()
                    else (
                          if !closureConversionDebug
                          then print (concat["Changed TUPLE for ", CV.toString param, " from: ",
                                             CPSTyUtil.toString (CV.typeOf param), " to: ",
                                             CPSTyUtil.toString newType, "\n"])
                          else ();
                          changed := true;
                          CV.setType (param, newType))
                end
              | _ => ()
        end
        and handleLambda(func as C.FB{f, params, rets, body}) = let
            val origType = CV.typeOf f
            val _ = List.app transformParam params
            val _ = List.app transformRet rets
	    val newType = case origType
                           of CTy.T_Fun _ => CTy.T_Fun (List.map CV.typeOf params, List.map CV.typeOf rets)
                            | CTy.T_Cont _ => CTy.T_Cont (List.map CV.typeOf params)
                            | _ => raise Fail (concat["Non-function type variable in a FB block: ", CV.toString f, " : ",
                                                      CPSTyUtil.toString origType])
            val _ = if CPSTyUtil.equal (origType, newType)
                    then ()
                    else (if !closureConversionDebug
                          then print (concat["Changed FB type for ", CV.toString f, " from: ",
                                             CPSTyUtil.toString origType, " to: ",
                                             CPSTyUtil.toString newType, "\n"])
                          else ();
                          changed := true;
                          CV.setType (f, newType))
	in
            walkBody (body)
	end
        and walkBody (C.Exp(_, e)) = (
            case e
             of C.Let (lhs, rhs, e) => (fixLet (lhs, rhs); walkBody (e))
              | C.Fun (lambdas, body) => (List.app handleLambda lambdas; walkBody (body))
              | C.Cont (f, body) => (handleLambda f; walkBody (body))
              | C.If (_, e1, e2) => (walkBody (e1); walkBody (e2))
              | C.Switch (_, cases, body) => (
                List.app (fn (_, e) => walkBody (e)) cases;
                Option.app (fn x => walkBody (x)) body)
              | C.Apply (_, _, _) => ()
              | C.Throw (_, _) => ())
        (*
         * If we change the signature of a function that was passed in as an argument
         * to an earlier function, we may need to go back and fix it up. Therefore, we
         * iterate until we reach a fixpoint.
         *)
        fun loopParams (fb) = (
            handleLambda (fb);
            if (!changed)
            then (changed := false; loopParams (fb))
            else ())
    in
        loopParams(fb)
    end

    (* env is a VMap.empty, CV.Var->CV.Var *)
    fun rename (env, x, y) = (
	(* every use of x will be replaced by a use of y *)
	  VMap.insert(env, x, y))

    (* apply a substitution to a variable *)
    fun subst (env, x) = (case VMap.find(env, x)
	   of SOME y => let
                  val xty = CV.typeOf x
                  val yty = CV.typeOf y
              in
                  if not(CPSTyUtil.equal (xty, yty))
                  then CV.setType (y, xty)
                  else ();
                  y
              end
	    | NONE => x
	  (* end case *))

    (* apply a substitution to a list of variables *)
    fun subst' (env, []) = []
      | subst' (env, x::xs) = subst(env, x) :: subst'(env, xs)

    (*
     * Convert does three things:
     * - Changes the FB param names from the "original" ones with associated
     * CFA info (so we could type-correct them!) to new ones, with the
     * copied type blasted to be equal to the one from the source
     * - Changes Apply/Throw to safe functions to take the new parameters
     * - Coerces any parameters to their required types as needed
     *)
    fun convert (env, C.MODULE{name,externs,body}) = let
        fun matchTypes (paramType::paramTypes, arg::orig, accum, final) = let
                val argType = CV.typeOf arg
            in
                if CPSTyUtil.equal (argType, paramType)
                then (print (concat[CV.toString arg, "=OK;"]); matchTypes (paramTypes, orig, arg::accum, final))
                else let
                        val typed = CV.new ("coerced", paramType)
                        val _ = if !closureConversionDebug
                                then print (concat["Coercing from: ",
                                                   CPSTyUtil.toString argType,
                                                   " to: ",
                                                   CPSTyUtil.toString paramType,
                                                   " for argument: ",
                                                   CV.toString arg, "\n"])
                                else ()
                    in
                        C.mkLet ([typed], C.Cast(paramType, arg),
                                 matchTypes (paramTypes, orig, typed::accum, final))
                    end
            end
          | matchTypes (paramTypes, [], accum, final) =
            (print "\n"; final (rev accum))
          | matchTypes (_, _, accum, final) =
            raise Fail (concat["Can't happen - call to method had mismatched arg/params."])
        fun getParamTypes f =
            case CV.typeOf f
             of CTy.T_Cont p => p
              | CTy.T_Fun (p,_) => p
              | _ => raise Fail (concat[CV.toString f, " not a fun or cont type"])
        fun convertFB (env, C.FB{f, params, rets, body}) =
            if getSafe f orelse (isCont f andalso case getContKind f of CALLEE_SAVE => true | _ => false)
            then let
                    val newArgsMap = getParams f
                    val oldNewList = VMap.listItemsi newArgsMap
                    val params = subst' (newArgsMap, params)
                    val env = List.foldr (fn ((x, y), m) => rename (m, x, y)) env oldNewList
                    val body = convertExp (env, body)
                in
                    C.FB{f=f, params=params, rets=rets, body=body}
                end
            else C.FB{f=f, params=params, rets=rets, body=convertExp (env, body)}
        and convertExp (env, C.Exp(ppt,t)) = (
            case t
             of C.Let (lhs, rhs, exp) => C.mkLet(lhs, convertRHS(env, lhs, rhs),
                                                 convertExp (env, exp))
              | C.Fun (lambdas, exp) => (C.mkFun (List.map (fn fb => convertFB (env, fb)) lambdas, convertExp (env, exp))) 
              | C.Cont (lambda, exp) => (C.mkCont (convertFB (env, lambda), convertExp (env, exp)))
              | C.If (cond, e1, e2) => C.mkIf(CondUtil.map (fn x => subst(env, x)) cond,
		                              convertExp(env, e1),
		                              convertExp(env, e2))
              | C.Switch(x, cases, dflt) => let
	            val x = subst(env, x)
	        in
	            C.mkSwitch (x,
		                List.map (fn (l, e) => (l, convertExp(env, e))) cases,
		                Option.map (fn e => convertExp(env, e)) dflt)
	        end
              | C.Apply(f, args, conts) => let
	            val f' = subst(env, f)
	            val args = subst'(env, args)
	            val conts' = subst'(env, conts)
                    val temp = CV.new ("anyCalleeA", CTy.T_Any)
                    fun handleCont k =
                        case getContKind k
                         of CALLEE_SAVE => (
                            case CV.kindOf k
                             of C.VK_Param _ => let
                                    val calleeParams = getCalleeParams k
                                    val nEmpties = nCalleeSaveRegs - (List.length calleeParams)
                                    val calleeParams = calleeParams @ List.tabulate (nEmpties, (fn _ => temp))
                                    val _ = print (concat[CV.toString k, " PARAM with ", Int.toString nEmpties,
                                                          " empties and calleeParams: ", String.concatWith "," (List.map CV.toString calleeParams),  "\n"])
                                in
                                    (calleeParams, nEmpties > 0)
                                end
                              | C.VK_Cont _ => let
                                    val calleeParams = getParams k
                                    val extras = List.map (fn (v,_) => v) (VMap.listItemsi calleeParams)
                                    val nEmpties = nCalleeSaveRegs - (List.length extras)
                                    val _ = print (concat[CV.toString k, " CONT with ", Int.toString nEmpties, " empties\n"])
                                in
                                    (extras @ (List.tabulate (nEmpties, (fn (_) => temp))),
                                     nEmpties > 0)
                                end
                              | _ => (print (concat[CV.toString k, " is CALLEE_SAVE w/ no params, generating 3 temps\n"]);
                                      (
                                      List.tabulate (nCalleeSaveRegs, (fn (_) => temp)),
                                      nCalleeSaveRegs > 0)))
                        | _ => ([], false)
                    val (calleeSaveParams, needsTemp) =
                        List.foldr (fn (k, (l,b)) => let
                                           val (l',b') = handleCont k
                                       in
                                           (l'@l, b' orelse b)
                                       end) ([],false) conts
                    fun maybeWrap w =
                        if needsTemp
                        then C.mkLet ([temp], C.Const(Literal.Enum(0w0), CTy.T_Any), w)
                        else w
	        in
                    case getSafeCallTarget f
                     of SOME a => let
                            val newArgsMap = getParams a
                            val newArgs = subst' (env, VMap.foldri (fn (v, _, l) => v::l) [] newArgsMap)
                            val args = args @ newArgs @ calleeSaveParams
                            val _ = if !closureConversionDebug
                                    then print (concat["Apply to safe call target through: ", CV.toString f,
                                                       " renamed to: ", CV.toString f', " safe call target named: ",
                                                       CV.toString a, "with args: ", String.concatWith "," (List.map CV.toString args),
                                                       "\n"])
                                    else ()       
                        in
                            maybeWrap (matchTypes (getParamTypes f', args, [], fn (args) =>
                                                                                  C.mkApply (f', args, conts')))
                        end
                      | NONE => let
                            val _ = if !closureConversionDebug
                                    then print (concat["Apply to unsafe call target through: ", CV.toString f,
                                                       " renamed to: ", CV.toString f', "with args: ",
                                                       String.concatWith "," (List.map CV.toString args), "\n"])
                                    else ()
                            val args = args @ calleeSaveParams
                        in
                        maybeWrap (matchTypes (getParamTypes f', args, [], fn (args) =>
                                                                                  C.mkApply (f', args, conts')))
                        end
	        end
              | C.Throw(k, args) => let
	            val k' = subst(env, k)
	            val args = subst'(env, args)
	        in
                    case getSafeCallTarget k
                     of SOME a => let
                            val newArgsMap = getParams a
                            val newArgs = subst' (env, VMap.foldri (fn (v, _, l) => v::l) [] newArgsMap)
                            val args = args @ newArgs
                            val _ = if !closureConversionDebug
                                    then print (concat["Throw to safe call target through: ", CV.toString k,
                                                       " renamed to: ", CV.toString k', " safe call target named: ",
                                                       CV.toString a, "with args: ", String.concatWith "," (List.map CV.toString args),
                                                       "\n"])
                                    else ()       
                        in
                            matchTypes (getParamTypes k', args, [], fn (args) => C.mkThrow (k', args))
                        end
                      | NONE => let
                            val _ = if !closureConversionDebug
                                    then print (concat["Throw to unsafe call target through: ", CV.toString k,
                                                       " renamed to: ", CV.toString k', " with args: ",
                                                       String.concatWith "," (List.map CV.toString args), "\n"])
                                    else ()
                        in
                            case getContKind k
                             of CALLEE_SAVE => (
                                (*
                                 * Params will have been annotated with the callee-save params.
                                 * Let-bound continuations are just "unused" thunks introduced in earlier
                                 * optimizations.
                                 * Otherwise, it's the name of an FB itself and we need to check that
                                 * for its params.
                                 *)
                                case CV.kindOf k'
                                 of C.VK_Param _ => let
                                        val calleeParams = getCalleeParams k
                                        val nEmpties = nCalleeSaveRegs - (List.length calleeParams)
                                    in
                                        if nEmpties = 0
                                        then C.mkThrow (k', args @ calleeParams)
                                        else let
                                                val temp = CV.new ("anyCalleeT", CTy.T_Any)
                                                val args = args @ calleeParams @ (List.tabulate (nEmpties, (fn (_) => temp)))
                                            in
                                                C.mkLet ([temp], C.Const(Literal.Enum(0w0), CTy.T_Any),
                                                         matchTypes (getParamTypes k', args, [], fn (args) => C.mkThrow (k', args)))
                                            end
                                    end
                                  | C.VK_Cont _ => let
                                        val calleeParams = getParams k
                                        val extras = List.map (fn (v,_) => v) (VMap.listItemsi calleeParams)
                                        val nEmpties = nCalleeSaveRegs - (List.length extras)
                                    in
                                        if nEmpties = 0
                                        then let
                                                val args = args @ extras
                                            in
                                                matchTypes (getParamTypes k', args, [], fn (args) => C.mkThrow (k', args))
                                            end
                                        else let
                                                val temp = CV.new ("anyCalleeT", CTy.T_Any)
                                                val args = args @ extras @ (List.tabulate (nEmpties, (fn (_) => temp)))
                                            in
                                                C.mkLet ([temp], C.Const(Literal.Enum(0w0), CTy.T_Any),
                                                         matchTypes (getParamTypes k', args, [], fn (args) => C.mkThrow (k', args)))
                                            end
                                    end
                                  | _ => let
                                        val temp = CV.new ("anyCalleeT", CTy.T_Any)
                                        val args = args @ (List.tabulate (nCalleeSaveRegs, (fn (_) => temp)))
                                    in
                                        C.mkLet ([temp], C.Const(Literal.Enum(0w0), CTy.T_Any),
                                                 matchTypes (getParamTypes k', args, [], fn (args) => C.mkThrow (k', args)))
                                    end)
                              | _ => matchTypes (getParamTypes k', args, [], fn (args) => C.mkThrow (k', args))
                        end
	        end)
        and convertRHS(env, _, C.Var(vars)) = C.Var(subst'(env,vars))
          | convertRHS(env, [l], C.Cast(ty,v)) = C.Cast(CV.typeOf l,subst(env,v))
          | convertRHS(env, _, C.Select(i,v)) = C.Select(i,subst(env,v))
          | convertRHS(env, _, C.Update(i,v1,v2)) = C.Update(i,subst(env,v1),subst(env,v2))
          | convertRHS(env, _, C.AddrOf(i,v)) = C.AddrOf(i, subst(env,v))
          | convertRHS(env, _, C.Alloc(ty,vars)) = C.Alloc(ty, subst'(env,vars))
          | convertRHS(env, _, C.Promote (v)) = C.Promote(subst(env,v))
          | convertRHS(env, _, C.Prim(p)) = C.Prim(PrimUtil.map (fn x => subst(env, x)) p)
          | convertRHS(env, _, C.CCall (var, vars)) = C.CCall (var, subst'(env,vars))
          | convertRHS(env, _, C.VPLoad(off,var)) = C.VPLoad (off, subst(env,var))
          | convertRHS(env, _, C.VPStore (off, v1, v2)) = C.VPStore (off, subst(env, v1), subst(env,v2))
          | convertRHS(env, _, C.VPAddr (off, var)) = C.VPAddr (off, subst(env, var))
          | convertRHS(env, _, x) = x
    in
        C.MODULE{
        name=name, externs=externs,
        body = convertFB (VMap.empty, body)}
    end

(*
 * this implements S&A
 *)
(* TODO: Figure out how to properly handle whatMap, whereMap, and baseRegs *)
    fun makeCPS (CPS.MODULE{body, ...}, whatMap, whereMap, baseRegs) = let
	val changed = ref false
	fun mergeFVMaps (maps) = let
	    fun mergeMaps ([], final) = final
	      | mergeMaps (m::maps, final) =
		mergeMaps (maps,
			   (VMap.foldli (fn (v, p as (fut, lut), final) =>
					    case VMap.find (final, v)
     					      of NONE => (changed := true; VMap.insert (final, v, p))
					       | SOME (fut', lut') => (
						 if (fut < fut' orelse lut > lut')
						 then (
						 changed := true;
						 VMap.insert (final, v, (Int.min (fut, fut'),
									 Int.max (lut, lut'))))
						 else final))
			    final m))
	in
	    case maps
	      of [] => VMap.empty
	       | [m] => m
	       | m::ms => mergeMaps(ms,m)
	end
	fun mergeRecCalls (recs, fMap) = (
	    case recs
	      of g::gs => (case VMap.find (fMap, g)
			     of SOME (futg, lutg) => let
				    val newMap = VMap.map (fn p => (futg, lutg)) (getFVMap g)
				    val mergedMap = mergeFVMaps([fMap, newMap])
				  in
				    mergeRecCalls (gs, mergedMap)
				  end
			      | NONE => mergeRecCalls (gs, fMap))
	       | [] => fMap)
        fun transClos (fbs, recs) = (
	    List.app (fn fb as C.FB{f, params, rets, body} => setFVMap (f, mergeRecCalls(recs, getFVMap f))) fbs;
	    if (!changed)
	    then (changed := false; transClos (fbs, recs))
	    else ())
        (* Note that we can remove not only the function itself (in the case that it is recursive),
	 * but also any functions that are (potentially) mutually recursive with it, because all of
         * their vars will already be available to us, since we have already calculated the transitive
	 * closure.
	 *)


(*
 * Let's see. I want to merge the closure contents (from whatMap) for each function
 * definition variable in the FVMap of f, but I also want to remove these function
 * definition variables themselves...
*)

	fun getTrueFreeVars (f, recs) = let
	    fun getClosures (v, p as (fut, lut), (cs, nonFuncs)) = (
		case CV.typeOf v
		  of CTy.T_Fun _ => ((if List.exists (fn x => CV.same(x,v)) recs
				     then cs
				     else
				       (case VMap.find (whatMap, v)
				         of SOME c => let val c0 = VMap.map (fn q => (fut, lut)) c in c0::cs end (* modulo implementation details of whatMap *)
				          | NONE => cs)), nonFuncs) (* do i really want to remove (v,p) in this case? *)
		   | _ => (cs, VMap.insert(nonFuncs, v, p)))
	    val (closures, nonFuncs) = VMap.foldli getClosures ([], VMap.empty) (getFVMap f)
	in
	    mergeFVMaps (nonFuncs::closures)
        end
	(* For the time being I am going to assume the following about whatMap and whereMap:
         * I am going to represent a closure as a pair (cr,clo) where cr is a new CV.Var I will
	 * introduce, representing the pointer to the closure record. This is so I can stick a
	 * closure in a varmap type-safely. clo will be the actual varmap that is the closure.
	 * whatMap will be a mapping from function names to their (cr,clo) pair.
	 * whereMap is just going to be a list of (cr,clo) pairs (i think).
	 *)
	fun shareClosures (f, whereMap) = let
	    val map = getFVMap f (* this is now the true free vars *)
	    val m = VMap.numItems map
	    val n = getSlot f (* assumes setSlots already called *)
		    (* TODO: Go through setSlot/getSlot and remove all the nCalleeSaveRegs stuff. *)
	in
	    if m > n
	    then let
		    (* this is the predicate that makes the sharing safe for space *)
		    fun subset(submap) = let
			fun subset0([]) = true
			  | subset0((v,p)::xs) = (
			    case VMap.find (map, v)
			     of SOME _ => subset0(xs)
			      | NONE => false)
		    in
			subset0 (VMap.listItemsi submap)
		    end
		    fun findBest(best, _, []) = best
		      | findBest(best, n, (v,c)::xs) = let
			val n0 = VMap.numItems c
			in
			    if n < n0
			    then findBest((v,c), n0, xs)
			    else findBest(best, n, xs)
			end
		    val safeClosures = List.filter (fn (v,c) => subset c) whereMap
		    (* What exactly is the "best fit" heuristic?
		     * In particular, do I want to choose only one closure from safeClosures,
		     * or might I want to choose more than one to form a cover?
		     * In that case it becomes much more complicated. *)
		    val (bestV, bestC) = findBest((f,VMap.empty), 0, safeClosures)
		    (* The above is really hackish, but I don't care what the initial
		     * value of v is, so we may as well use f since we have it around. *)
		in
		    if VMap.numItems bestC > 1 (* rules out the empty case as well *)
		    then let
			    fun removeAll ([], p, map) = (p, map)
			      | removeAll ((v,p)::rems, (fut, lut), map) = let
				    val (map, (fut0, lut0)) = VMap.remove(map, v)
				    val (fut, lut) = (Int.min(fut, fut0), Int.max(lut, lut0))
				in
				    removeAll (rems, (fut, lut), map)
				end
			    val bestList = VMap.listItemsi bestC
			    val (v,q) = List.hd bestList
			    val (p,map) = removeAll(bestList, q, map)
			(* That looks hackish. Is there a better way to do it? *)
			in
			    VMap.insert(map, bestV, p)
			end
		    else map (* Don't waste my time. *)
		end
	    else map (* if |TFV(f)| < slots(f) there is nothing to do *)
	end

	fun alloc (slots, vars, f) = let
	    (* This predicate is true iff p1 is "favored" over p2, according to S&A:
	     * "First, we favor variables with the smaller lut number.
	     * Second, we select those variables with the smaller fut number."
	     * Favors p1 if both p1 and p2 have the same fut and lut numbers. *)
	    fun favored(p1 as (v1, (futv1, lutv1)), p2 as (v2, (futv2, lutv2))) =
		if (lutv1 < lutv2 orelse (lutv1 = lutv2 andalso futv1 <= futv2))
		then true
		else false

	    val findWorst = VMap.foldli (fn (v, (futv, lutv), p) => if favored (p, (v, (futv, lutv))) then (v, (futv, lutv)) else p) (f, (~1, ~1))

	    fun alloc0(count, regs, worst, heap, []) = (regs, heap)
	      | alloc0(count, regs, worst, heap, v::vs) =
		if (count < slots - 1)
		then
		    if favored(worst, v)
		    then alloc0(count + 1, VMap.insert'(v, regs), v, heap, vs)
		    else alloc0(count + 1, VMap.insert'(v, regs), worst, heap, vs)
		else
		    if favored(worst, v)
		    then alloc0(count, regs, worst, VMap.insert'(v, heap), vs)
		    else
			let
			    val regs = VMap.insert'(v, #1 (VMap.remove(regs, #1 worst)))
			    val heap = VMap.insert'(worst, heap)
			    val worst = findWorst regs
			in
			    alloc0(count, regs, worst, heap, vs)
			end
	in
	    alloc0(0, VMap.empty, (f, (~1, ~1)), VMap.empty, vars)
	end


	fun doLambda (recs, fb as CPS.FB{f, params, body, rets}) = (
	    (* By this point the transitive closure has already been calculated.
	     * First we calculate the true free variables. *)
	    setFVMap (f, getTrueFreeVars(f, recs));
	    (* 4.4.3: Sharing w/ closures in cur. env. *)
	    setFVMap (f, shareClosures(f, whereMap));
	    (* 4.4.4: decide which vars go in regs and which go on the heap. *)
	    let
		val map = getFVMap f
		val m = VMap.numItems map
		val n = getSlot f
		val (regs, heap) = if m > n then alloc (n, VMap.listItemsi map, f) else (map, VMap.empty)
	    in
		()
	    end;
	    


	    (* other stuff in the algorithm goes here *)
	    doExp body)
	and doExp (CPS.Exp(_, e)) = (
	    case e
	      of CPS.Let(_, _, e) => (doExp e)
	       | CPS.Fun(fbs, e) => let
		     val recs = List.map (fn fb as CPS.FB{f,...} => f) fbs
		 in
		     transClos(fbs, recs);
		     List.app (fn fb => doLambda (recs, fb)) fbs;
		     doExp e
		 end
	       | CPS.Cont(fb, e) => (doExp e)
	       | CPS.If(_, e1, e2) => (doExp e1 ; doExp e2)
	       | CPS.Switch(_, cases, dflt) => (
		 List.app (fn c => doExp (#2 c)) cases;
		 Option.app doExp dflt)
	       | CPS.Apply _ => ()
	       | CPS.Throw _ => ()
	(* end case *))
(*	fun loop (fb) = (
	    doLambda ([], fb);
	    if (!changed)
	    then (changed := false; loop (fb))
	    else ()) *)
    in
	doLambda ([], body)
    end

(* Calculates the true free variables.
 * Implements S&A section 4.4.2.
 *)
(*    fun getTrueVars (CPS.MODULE{body, ...}) = let
	val changed = ref false
	fun mergeFVMaps (maps) = let
	    fun mergeMaps ([], final) = final
	      | mergeMaps (m::maps, final) =
		mergeMaps (maps,
			   (VMap.foldli (fn (v, p as (fut, lut), final) =>
					    case VMap.find (final, v)
     					      of NONE => (VMap.insert (final, v, p); changed := true)
					       | SOME (fut', lut') => (
						 if (fut < fut' orelse lut > lut')
						 then (
						 changed := true;
						 VMap.insert (final, v, (Int.min (fut, fut'),
									 Int.max (lut, lut'))))
						 else final))
			    final m))
	in
	    case maps
	      of [] => VMap.empty
	       | [m] => m
	       | m::ms => mergeMaps(ms,m)
	end
	fun mergeRecCalls (recs, fMap) = (
	    case recs
	      of g::gs => (case VMap.find (fMap, g)
			     of SOME (futg, lutg) => let
				    val newMap = VMap.map (fn p => (futg, lutg)) (getFVMap g)
				    val mergedMap = mergeFVMaps([fMap, newMap])
				  in
				    mergeRecCalls (gs, mergedMap)
				  end
			      | NONE => mergeRecCalls (gs, fMap))
	       | [] => fMap)
	fun doLambda' (fb as C.FB{f, params, rets, body}) = (
	    let
		fun replace (v, p as (fut, lut), newMap) = (
		    case CV.typeOf v
		      of CTy.T_Cont _ => VMap.empty (* callee-save vars *)
		       | CTy.T_Fun _ => VMap.empty (* closure contents (ie slot vars) *)
		       | _ => VMap.insert (newMap, v, p))
	    in
		VMap.foldli replace VMap.empty (getFVMap f)
	    end
	fun doLambda (fb as CPS.FB{f, params, rets, body}, recs) = (
	    setFVMap (f, mergeRecCalls(recs, getFVMap f));
	    doExp body)
	and doExp (CPS.Exp(_, e)) = (
	    case e
	      of CPS.Let(_, _, e) => (doExp e)
	       | CPS.Fun(fbs, e) => let
		     val recs = List.map (fn gb as CPS.FB{g,...} => g) fbs
		 in
		     List.app (fn fb => doLambda(fb, recs)) fbs;
		     doExp e
		 end
	       | CPS.Cont(fb, e) => (doLambda (fb, []); doExp e)
	       | CPS.If(_, e1, e2) => (doExp e1 ; doExp e2)
	       | CPS.Switch(_, cases, dflt) => (
		 List.app (fn c => doExp (#2 c)) cases;
		 Option.app doExp dflt)
	       | CPS.Apply _ => ()
	       | CPS.Throw _ => ()
	(* end case *))
	fun loop (fb) = (
	    doLambda (fb, []);
	    if (!changed)
	    then (changed := false; loop (fb))
	    else ())
    in
	loop(body)
    end

*)

(* translate should be the function that actually transforms the CPS module to a CFG module
 *)
(*
  fun translate (env, C.MODULE{name,externs,body}) = let
      fun translateFB (whatMap, whereMap, baseRegs, C.FB{f, params, rets, body}) =
	  (* the first thing we do is find the transitive closure of raw free variables *)





      in
      C.MODULE{
      name=name, externs=externs,
      body = translateFB (VMap.empty, VMap.empty, VMap.empty, body)}
      end
*)
(*
 * The first thing we want to do is CFA. Our compiler already does CFA, so I don't need
 * to implement Section 4.1 in S&A.
 * I don't have to implement 4.2 either, because we already have a function for calculating
 * the raw free variables, and the calculation of their lifetime information (stage number, fut, lut)
 * was implemented above by Lars.
 * I don't really have to do anything for 4.3 either, because that was also implemented by Lars.
 * Note however that I should change it so nCalleeSaveRegs = 0.
 * 4.4 is the main thing I have to implement.
 *)

    fun transform module =
        if !enableClosureConversion
        then let
                val _ = FreeVars.analyze module
                val _ = CFACPS.analyze module
                val funs = getSafeFuns module
                val _ = setSNs module
                val _ = updateLUTs module
                val _ = setSlots funs
                val _ = computeParams module
                val _ = reduceParams funs
                val module = addParams module
                val _ = propagateFunChanges module
                val module = convert (VMap.empty, module)
                val _ = CFACPS.clearInfo module
                val _ = FreeVars.clear module
	        val _ = CPSCensus.census module
            in
                module
            end
        else module
end
