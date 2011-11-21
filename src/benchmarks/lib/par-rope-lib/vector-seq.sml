(* vector-seq.sml
 *
 * COPYRIGHT (c) 2009 The Manticore Project (http://manticore.cs.uchicago.edu)
 * All rights reserved.
 *
 * Vector sequences.
 * 
 * Authors:
 *   Mike Rainey (mrainey@cs.uchicago.edu)
 *   Adam Shaw (ams@cs.uchicago.edu)
 *
 *)

structure VectorSeq : SEQ = 
  struct

    structure V = Vector

    type 'a seq = 'a vector

    datatype progress = datatype ProgressTy.progress

    val fromList = V.fromList

    fun fromListRev xs = fromList (List.rev xs)

    fun empty () = fromList List.nil

    fun singleton s = fromList (s :: List.nil)

    fun isEmpty v = V.length v = 0

    val length = V.length

    val sub = V.sub
    val update = V.update

    val tabulate = V.tabulate

    fun append (x, y) = let
      val xn = length x
      val yn = length y
      fun elt i =
	if i < xn then
	  sub (x, i)
	else
	  sub (y, i-xn)
      in
	tabulate (xn+yn, elt)      
      end

    fun toList v = V.foldr (fn (x, ls) => x :: ls) [] v

    fun rev s = let
      val len = length s
      in
	tabulate (len, fn i => sub (s, len - i - 1))
      end

    val map = V.map

    fun mapPartial _  = raise Fail "todo"

    val foldl = V.foldl

    val foldr = V.foldr

    fun take (s, n) = let
      val len = length s
      in
	if n >= len then s
	else tabulate (n, fn i => sub (s, i))
      end

    fun drop (s, n) = let
      val len = length s
      in
	if n >= len then (empty())
	else tabulate (len-n, fn i => sub (s, i+n))
      end

    fun delete (s, i) = 
	let
	    fun f j = if j < i then sub (s, j) else sub (s, j + 1)
	in
	    tabulate (length s - 1, f)
	end

    fun cut (s, n) = (take (s, n), drop (s, n))

    fun filter pred s =
      if isEmpty s then (empty())
      else let
	val len = length s
	fun lp (i, acc) = 
	  if i < 0 then
	    fromList acc
	  else let
	    val x = sub (s, i)
	    in
	      if pred x then lp (i-1, x::acc)
	      else lp (i-1, acc) 
	    end
	in
	  lp (len-1, nil)
	end

    val app = V.app

    fun subseq (xs, st, len) = take (drop (xs, st), len)

    val find = V.find

    val exists = V.exists

    val all = V.all

  (* mapUntil k cond f s *)
  (* returns either the result of mapping f over s or, if cond () returns true the pair (unprd, prd). *)
  (* - unprd records the elements yet to be processed and prd processed ones *)
  (* - k is the number of elements to process before checking the condition *)
  (* pre: k > 0 *)
    fun mapUntil k cond f s =
	let fun advanceK k' = if k' <= 1 then k else k' - 1
	    val len = length s
	    fun mp (i, k', res) =
		if i >= len then COMPLETE (fromListRev res)
		else if k' <= 1 andalso cond () then PARTIAL (drop (s, i), fromListRev res)
		else mp (i + 1, advanceK k', f (V.sub (s, i)) :: res)
	in
	    if cond () then PARTIAL (s, empty ()) else mp (0, k, nil)
	end

  (* filterUntil k cond pred s *)
  (* returns either the result of filtering s by pred or, if cond () returns true the pair (unprd, prd) *)
  (* - unprd records the unprocessed elements and prd is the processed ones *)
  (* - k is the number of elements to process before checking the condition *)
  (* pre: k > 0 *)
    fun filterUntil k cond f s =
	let fun advanceK k' = if k' <= 1 then k else k' - 1
	    val len = length s
	    fun flt (i, k', res) =
		if i >= len then COMPLETE (fromListRev res)
		else if k' <= 1 andalso cond () then PARTIAL (drop (s, i), fromListRev res)
		else let val x = V.sub (s, i)
		     in
			 flt (i + 1, advanceK k', if f x then x :: res else res)
		     end
	in
	    if cond () then PARTIAL (s, empty ()) else flt (0, k, nil)
	end

  (* reduceUntil k cond aop z s *)
  (* returns either the reduction z aop s_0 aop s_1 ... aop s_n or, if cond () returns true, *)
  (* the pair (unprd, acc) where unprd records the unprocessed elements and acc the result of the reduction at the *)
  (* point of interruption *)
  (* - k is the number of elements to process before checking the condition *)
  (* pre: aop is an associative operator *)
    fun reduceUntil k cond aop z s =
	let fun advanceK k' = if k' <= 1 then k else k' - 1
	    val len = length s
	    fun red (i, k', acc) =
		if i >= len then COMPLETE acc
		else if k' <= 1 andalso cond () then PARTIAL ((drop (s, i), take (s, i)), acc)
		else red (i + 1, advanceK k', aop (acc, sub (s, i)))
	in
	    if cond () then PARTIAL ((s, empty ()), z) else red (0, k, z)
	end

    fun tabulateUntil k cond (lo, hi, f) =
	let fun advanceK k' = if k' <= 1 then k else k' - 1
	    val len = hi - lo + 1
	    fun tab (i, k', acc) =
		if i >= len then COMPLETE (fromListRev acc)
		else if k' <= 1 andalso cond () then PARTIAL ((), fromListRev acc)
		else tab (i + 1, advanceK k', f (i + lo) :: acc)
	in
	    if cond () then PARTIAL ((), empty ()) else tab (0, k, nil)
	end

    fun scanl aop z s = 
	let
	    val len = length s
	    fun scn (i, acc, res) =
		if i >= len then (fromListRev res, acc)
		else scn (i + 1, aop (acc, V.sub (s, i)), acc :: res)
	in
	    scn (0, z, nil)
	end

    fun scanlUntil k cond aop z s = 
	let fun advanceK k' = if k' <= 1 then k else k' - 1
	    val len = length s
	    fun scn (i, k', acc, res) =
		if i >= len then COMPLETE (fromListRev res, acc)
		else if k' <= 1 andalso cond () then PARTIAL (drop (s, i), (fromListRev res, acc))
		else scn (i + 1, advanceK k', aop (acc, V.sub (s, i)), acc :: res)
	in
	    if cond () then PARTIAL (s, (empty (), z)) else scn (0, k, z, nil)
	end

    structure Pair = VectorSeqPair

  end
