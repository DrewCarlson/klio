// A bare call to a same-named extension function inside an extension body
// binds the overload whose receiver type matches the *enclosing* receiver,
// not an arity-equal extension on a different type. Inside `fun A.describe()`
// the bare `tag()` is `this.tag()` and must reach `A.tag`, even though a
// same-named `B.tag` of equal arity also exists. This is ktor's
// `fun Source.forEach { … takeWhile { … } }`, where `takeWhile` must bind
// `Source.takeWhile`, not stdlib `CharSequence.takeWhile`.
class A
class B

fun A.tag(): String = "tagA"
fun B.tag(): String = "tagB"

fun A.describe(): String = "describe(${tag()})"
fun B.describe(): String = "describe(${tag()})"

fun A.wrap(label: String): String = "$label:${tag()}"

fun main() {
    println(A().describe())
    println(B().describe())
    println(A().wrap("x"))
}
