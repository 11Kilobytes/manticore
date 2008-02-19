(* dt01.pml *)

type vec = (float * float * float);
datatype Light
  = Directional of (vec * vec)		(* direction, color *)
  | Point of (vec * vec)		(* position, color *)
  ;
fun lightcolor l = (case l
       of (Directional(_, c)) => c
	| (Point(_, c)) => c
      (* end case *));

fun v2s (x,y,z) = ftos x^" "^ftos y^" "^ftos z^"\n";

print (v2s (lightcolor (Point ((0.0,0.0,0.0), (2.3,4.3,1.1)))))

