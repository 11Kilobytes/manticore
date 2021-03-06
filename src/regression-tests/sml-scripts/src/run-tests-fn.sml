(* run-tests-fn.sml
 *
 * COPYRIGHT (c) 2008 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * A script to run the tests in the goals directory and generate reports.
 *)

functor RunTestsFn (L : COMPILER) = struct

  structure H = MiniHTML
  structure F = OS.FileSys
  structure P = OS.Path
  structure T = Tests
  structure U = Utils

  fun println s = (print s; print "\n")

  val sys = OS.Process.system

  fun joinDF (d, f) = P.joinDirFile {dir=d, file=f}
  fun joinBE (b, e) = P.joinBaseExt {base=b, ext=SOME(e)}

  fun printErr s = (TextIO.output (TextIO.stdErr, s); 
		    TextIO.flushOut TextIO.stdErr)

(* executeNullErr : string * string list -> ('a, 'b) Unix.proc * TextIO.instream * TextIO.outstream *)
(* Wraps Unix.execute with redirection of stderr to /dev/null. *)
  fun executeNullErr (prog, args) = let
    val origErr = Posix.IO.dup Posix.FileSys.stderr
    val nullErr = Posix.FileSys.openf ("/dev/null", Posix.FileSys.O_WRONLY, Posix.FileSys.O.flags [])
    val () = Posix.IO.dup2 {new=Posix.FileSys.stderr, old=nullErr}
    val p = Unix.execute (prog, args)
    val () = Posix.IO.dup2 {new=Posix.FileSys.stderr, old=origErr}
    in
      Posix.IO.close origErr;
      Posix.IO.close nullErr;
      (p, Unix.textInstreamOf p, Unix.textOutstreamOf p)
    end

(* runTest : date * string -> {outcome:T.outcome, expected:string, actual:string} *)
  fun runTest (d, filename) = let
    val shortName = joinDF (P.file (P.dir filename), P.file filename)
    val _ = print ("testing " ^ shortName ^ "...")
    val cwd = F.getDir ()
    val exeFile = L.mkExe filename
    val okFile = joinDF (P.dir filename,
			 joinBE (P.file (P.base filename), "ok"))
    val resFile = U.freshTmp (cwd, "results")
    val compileCmd = L.mkCmd filename
    (* val _ = printErr (concat ["The compiler command is ", compileCmd, "\n"]) *)
    (* val compileSucceeded = sys compileCmd *)
    val (cmpProc, cmpIns, _) = executeNullErr (L.getCompilerPath(), [filename])
    val compilerOutput = let
      fun loop acc = 
       (case TextIO.inputLine cmpIns
          of SOME str => loop (str::acc)
	   | NONE => concat (rev acc))
      in
        loop []
      end
    val compileSucceeded = Unix.reap cmpProc
    val tmps = exeFile :: resFile :: L.detritus filename
    fun cleanup () = app U.rm tmps
    in
     (if compileSucceeded = OS.Process.success then let
        val diffFile = U.freshTmp (cwd, "diffs")
        val makeOutput = sys (concat ["./", exeFile, " > ", resFile])
	val diffCmd = concat ["diff ", resFile, " ", okFile, " > ", diffFile]
	val diffSucceeded = sys diffCmd 
        val actual = String.concatWith "\n" (U.textOf resFile)
	in
          if diffSucceeded = 0 then let	
	    val expected = String.concatWith "\n" (U.textOf okFile)
            in
	      {outcome = if F.fileSize diffFile = 0 then T.TestSucceeded else T.TestFailed,
	       expected = expected,
	       actual = actual}
	      before U.rm diffFile
	    end
	  else
	    (println ("WARNING: no .ok file for " ^ shortName);
	     U.rm diffFile;
	     {outcome = T.TestFailed, expected = "*** No .ok file! ***", actual = actual})
        end
      else
        {outcome = T.DidNotCompile compilerOutput,
	 expected = "",
	 actual = ""})
     before (println "done";
	     cleanup ())
    end

(* runGoal : date * string -> string -> T.goal *)
  fun runGoal (d, ver) goalDir = let
    val ts = U.filesWithin (String.isSuffix ("." ^ L.ext)) goalDir
    val readme = T.readRawReadme d (joinDF (goalDir, "README"))
    val g = OS.Path.file goalDir
    fun mk t = let
      val {outcome, expected, actual} = runTest (d, t)
      in
        T.TR {stamp = T.STAMP {timestamp=d, version=ver},
	      goalName = g,
	      testName = OS.Path.file t,
	      outcome = outcome,
 	      expected = expected,
	      actual = actual}
      end
    in 
      T.G (readme, map mk ts)
    end

(* run : string option -> T.report *)
  fun run optDir = let
    val quickie = false (* set this to true to do just a few tests *)
    val now = Date.fromTimeLocal (Time.now ())
    val ver = U.currentRevision ()
    (* val _ = (print Locations.goalsDir; print "\n"; raise Fail "stop") *)
    val noHidden = List.filter (not o (String.isPrefix ".") o OS.Path.file)
    val goals = noHidden (U.dirsWithin Locations.goalsDir)
    val goals' = if quickie 
		 then [hd goals] 
		 else (case optDir
                         of NONE => goals
			  | SOME dir => List.filter (fn g => OS.Path.file g = dir) goals
		         (* end case *))
    in
      map (runGoal (now, ver)) goals'
    end 

end
