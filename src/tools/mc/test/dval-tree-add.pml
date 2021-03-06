(* not real pml; this program uses the "dval" binder *)
datatype tree = EMPTY | NODE of (int * tree * tree);

fun treeAdd t = (case t
    of EMPTY => 0
     | NODE (i, l, r) => let
       dval x = treeAdd(l)
       val y = treeAdd(r) + i
       in
          x + y
       end
    (* end case *));

val _ = treeAdd (NODE(1, EMPTY, EMPTY))

