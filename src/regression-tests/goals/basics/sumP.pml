val (ns : int parray) = [| 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
                           10, 10, 10, 10, 10, 10, 10, 10, 10, 10 |];
                        (* That's 1100 total. *)

fun add (a : int, b) = a+b;
val s = PArray.reduce (add, 0, ns);

val _ = print ("The answer is " ^ (Int.toString s) ^ ". (Expected 1100.)\n")
