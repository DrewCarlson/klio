// A nested object/class whose simple name collides with a true top-level
// type must not overwrite it: the top-level keeps the bare name, and the
// nested resolves through its qualifier.
class Other { val top: Int = 1 }

class Outer {
    object Other { val v: Int = 9 }
    class Inner(val n: Int)
    fun useNested(): Int = Other.v
}

object Application { fun who(): String = "top-level" }

class Holder {
    object Application { fun who(): String = "nested" }
}

fun main() {
    println(Other().top)            // 1  (top-level class, not the nested object)
    println(Outer.Other.v)          // 9  (nested object via qualifier)
    println(Outer().useNested())    // 9  (bare access inside the outer)
    println(Application.who())      // top-level
    println(Holder.Application.who()) // nested
}
