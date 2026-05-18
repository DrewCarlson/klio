// A named argument on a member / extension call binds by the
// callee's parameter name, filling an omitted *leading* defaulted
// parameter from its default — `recv.f(h = x)` for
// `fun R.f(flag: Boolean = true, h: H)` binds `h`, never shifting
// `x` into `flag`. Mirrors upstream `Job.invokeOnCompletion(
// invokeImmediately = true, handler)` called as
// `deferred.invokeOnCompletion(handler = node)`.

class H(val tag: String)

class Box(val id: Int)

fun Box.label(prefix: String = "P", h: H): String = "$id:$prefix:${h.tag}"

class Recv
fun Recv.run2(flag: Boolean = true, h: H): String = "$flag/${h.tag}"

fun main() {
    val b = Box(7)
    println(b.label(h = H("a")))
    println(b.label("Q", H("b")))
    println(b.label(prefix = "Z", h = H("c")))
    val r = Recv()
    println(r.run2(h = H("x")))
    println(r.run2(flag = false, h = H("y")))
}
