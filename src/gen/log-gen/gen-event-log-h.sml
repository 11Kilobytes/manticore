(* gen-inline-log-h.sml
 *
 * COPYRIGHT (c) 2008 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Generate the "inline-log.h" file.
 *)

structure GenEventLogH : GENERATOR =
  struct

    structure Sig = EventSig
    structure Map = Sig.Map

    val template = "event-log_h.in"
    val path = "src/lib/parallel-rt/include/event-log.h"

    fun ghc attrs = List.exists(fn attr => attr = LoadFile.ATTR_GHC) attrs
				  
  (* generate the inline logging function for a given signature *)
    fun genForSig outS (sign, {isSource, args}) = let
	fun pr s = TextIO.output(outS, s)
	fun prl l = TextIO.output(outS, concat l)
	(* generate params for the event arguments *)
	fun genParams ([], _)= ()
	  | genParams ((_, ty)::r, i) = let
	      fun next cty = (
		  prl [", ", cty, "a", Int.toString i];
		  genParams (r, i+1))
	  in
	      case ty
	       of Sig.ADDR => next "void *"
		| Sig.INT => next "int32_t "
		| Sig.WORD => next "uint32_t "
		| Sig.FLOAT => next "float "
		| Sig.DOUBLE => next "double "
		| Sig.EVENT_ID => next "uint64_t "
		| Sig.NEW_ID => (* this value is generated by logging function *)
		  genParams (r, i+1)
		| Sig.WORD16 => next "uint16_t "
		| Sig.WORD8 => next "uint8_t "
		| Sig.STR _ => next "const char *"
				    (* end case *)
	  end
	(*generate code to post the event data to the buffer*)
	fun genPosts([], _) = ()
	  | genPosts((loc, ty)::r, i) =
	    let val arg = "a" ^ Int.toString i
	    in 
		case ty
		 of Sig.INT => prl["    postWord32(vp->event_log, ", arg, ");\n"]
		  | Sig.WORD16 => prl ["    postWord16(vp->event_log, ", arg, ");\n"]
		  | Sig.WORD8 => prl ["    postWord8(vp->event_log, ", arg, ");\n"]
		  | Sig.WORD => prl ["    postWord32(vp->event_log, ", arg, ");\n"]
		  | Sig.NEW_ID => TextIO.output(outS, "    uint64_t newId = NewEventId(vp);\n    postWord64(vp->event_log, newId);\n")
		  | _ => prl["    postWord64(vp->event_log, (uint64_t)", arg, ");\n"]
	      ; genPosts(r, i+1)
	    end					    
	  in
	    prl [
		"STATIC_INLINE ",
		if isSource then "uint64_t" else "void",
		" LogEvent", sign, " (VProc_t *vp, uint16_t evt"
	      ];
	    genParams (args, 0);
	    pr "\
	      \)\n\
	      \{\n\
	      \    ensureRoomForEvent(vp, evt);\n\
              \    postWord16(vp->event_log, evt); \n\
	      \    LogTimestamp (vp->event_log);\n";
	    genPosts (args, 0);
	    if isSource
	      then pr "    return newId;\n"
	      else ();
	    pr "\n}\n\n"
	  end

  (* generate an event-specific logging macro *)
    fun genLogMacro outS (LoadFile.EVT{id=0, ...}) = ()
      | genLogMacro outS (LoadFile.EVT ed) = let
	  fun pr s = TextIO.output(outS, s)
	  fun prl l = TextIO.output(outS, concat l)
	  fun prParams [] = ()
	    | prParams ((a : Sig.arg_desc)::r) = (prl [",", #name a]; prParams r)
	  fun prArgs [] = ()
	    | prArgs ((a : Sig.arg_desc)::r) = (prl [", (", #name a, ")"]; prArgs r)
	(* filter out any new-id arguments *)
	  val args = List.filter (not o Sig.isNewIdArg) (#args ed)
	  in
	    prl ["#define Log", #name ed, "(vp"];
	    prParams args;
	    prl [") LogEvent", #sign ed, " ((vp), ", #name ed, if ghc (#attrs ed) then "" else "Evt"];
	    prArgs (Sig.sortArgs args); (* NOTE: location order here! *)
	    pr ")\n"
	  end

  (* generate a dummy logging macro for when logging is disabled *)
    fun genDummyLogMacro outS (LoadFile.EVT{id=0, ...}) = ()
      | genDummyLogMacro outS (LoadFile.EVT ed) = let
	  fun pr s = TextIO.output(outS, s)
	  fun prl l = TextIO.output(outS, concat l)
	  fun prParams [] = ()
	    | prParams ((a : Sig.arg_desc)::r) = (prl [",", #name a]; prParams r)
	  fun prArgs [] = ()
	    | prArgs ((a : Sig.arg_desc)::r) = (prl [", (", #name a, ")"]; prArgs r)
	(* filter out any new-id arguments *)
	  val args = List.filter (not o Sig.isNewIdArg) (#args ed)
	  in
	    prl ["#define Log", #name ed, "(vp"];
	    prParams args;
	    pr ") 0\n"
	  end
		      
  (* compute a mapping from signatures to their argument info from the list of event
   * descriptors.
   *)
    fun computeSigMap logDesc = let
	  val isSourceEvt = LoadFile.hasAttr LoadFile.ATTR_SRC
	  fun doEvent (evt as LoadFile.EVT{sign, args, ...}, map) = (case Map.find(map, sign)
		 of SOME _ => map
		  | NONE => let
		      val argInfo = {
			      isSource = isSourceEvt evt,
			      args = List.map (fn {loc, ty, ...} => (loc, ty)) args
			    }
		      in
			Map.insert (map, sign, argInfo)
		      end
		(* end case *))
	  in
	    LoadFile.foldEvents doEvent Map.empty logDesc
	  end

    fun hooks (outS, logDesc : LoadFile.log_file_desc) = let
	(* filter out the PML-only events *)
	val origDesc = logDesc
	  val logDesc = LoadFile.filterEvents (not o (LoadFile.hasAttr LoadFile.ATTR_PML)) logDesc
	  val sigMap = computeSigMap logDesc
	  fun genericLogFuns () = Map.appi (genForSig outS) sigMap
	  fun logFunctions () = LoadFile.applyToEvents (genLogMacro outS) logDesc
	  fun dummyLogFunctions () = LoadFile.applyToEvents (genDummyLogMacro outS) logDesc

	  fun prl l = TextIO.output(outS, concat l)

							    
	  fun prDesc(name, desc) = prl [
		  "     [", name, "] = \"", desc, "\",\n" 
	      ]
	  fun genDesc (LoadFile.EVT{id = 0, name, desc, ...}) = prDesc(name,desc)
	    | genDesc (LoadFile.EVT{id, name, desc, attrs, ...}) =
	      if ghc attrs
	      then prDesc(name, desc)
	      else prDesc(name ^ "Evt", desc)

	  fun prSizes(name, size) = prl [
		  "    [", name, "] = ", size, ",\n"]

	  fun computeSize(args : EventSig.arg_desc list) =
	      case args
	       of [] => "0"  
		| {ty, ...}::args => EventSig.strSizeofTy ty ^ " + " ^ computeSize args
		  				
	  fun genSizes(LoadFile.EVT{name, args, attrs, ...}) =
	      if ghc attrs
	      then prSizes(name, computeSize args)
	      else prSizes(name ^ "Evt", computeSize args)

	  in [
	    ("GENERIC-LOG-FUNCTIONS", genericLogFuns),
	    ("LOG-FUNCTIONS", logFunctions),
	    ("DUMMY-LOG-FUNCTIONS", dummyLogFunctions),
	    ("EVENT-DESC", fn () => LoadFile.applyToEvents genDesc origDesc),
	    ("EVENT-SIZES", fn () => LoadFile.applyToEvents genSizes origDesc)
	  ] end

  end
