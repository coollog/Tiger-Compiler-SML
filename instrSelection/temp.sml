(* make this an abstraction sometime *)
structure Temp : TEMP =
struct
  
  type temp = int
  val temps = ref 100
  fun newtemp() = let val t = !temps in temps := t+1; t end

  fun resetTempCount() = (temps := 100) (*Special registers already assigned*)

  structure Table = IntMapTable(type key = temp
			  fun getInt n = n)

  type 'a table= 'a Table.table
  val empty = Table.empty
  val enter = Table.enter
  val look = Table.look

  fun makestring t = "$t" ^ Int.toString t

  type label = Symbol.symbol

  local structure F = Format
        fun postinc x = let val i = !x in x := i+1; i end
        val labs = ref 0
   in
      fun newlabel() = Symbol.symbol(F.format "L%d" [F.INT(postinc labs)])
      val namedlabel = Symbol.symbol
  end

end
