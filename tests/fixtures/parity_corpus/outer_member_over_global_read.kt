// A bare read inside nested receivers: the innermost receiver does not
// own `z`, so the outer receiver's member binds — never the top-level
// binding, which sits below every receiver in scope. An extension
// receiver brings only itself: no enclosing-instance tower.
class A
class B { val z: String = "b-member" }
val z: String = "global"

class Owner {
    var status: String = "owner-value"
    inner class Pocket { var p: Int = 0 }
}
var status: String = "global"
fun Owner.Pocket.poke(): String = status

fun main() {
    with(B()) { with(A()) { println(z) } }
    println(Owner().Pocket().poke())
}
