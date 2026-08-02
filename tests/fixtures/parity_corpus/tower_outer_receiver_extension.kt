class Inner
class Outer(val tag: String)

fun Outer.describe(): String = "outer-extension:" + tag

fun withInner(block: Inner.() -> String): String = Inner().block()

fun Outer.probe(): String = withInner { describe() }

fun main() {
    println(Outer("a").probe())
    // Two levels: the middle lambda introduces its own receiver too.
    println(Outer("b").deep())
}

class Mid
fun withMid(block: Mid.() -> String): String = Mid().block()

fun Outer.deep(): String = withMid { withInner { describe() } }
