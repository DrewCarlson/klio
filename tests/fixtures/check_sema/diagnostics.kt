// `klio check --engine sema` names kotlinc's diagnostics; `@Suppress`
// silences the one it names over what it annotates.
fun greet(a: Int) = a
fun greet(b: Int) = b

@Suppress("UNRESOLVED_REFERENCE")
fun quiet() = missingButSuppressed

class Box {
    val size = 1
    val size = 2
}

fun main() {
    println(missing)
    val label: Strin = "box"
    println(label)
}
fun answer(): String = 42
val count: Int = "three"
fun twice(n: Int) = n * 2
val doubled = twice("2")
fun len(s: String?) = s.length
fun twiceVal(): Int { val x = 1; x = 2; return x }
suspend fun pause() {}
fun callsPause() { pause() }
fun sameText(n: Int, s: String) = n == s
internal fun hidden(x: Int) = x
inline fun exposes(x: Int) = hidden(x)
class Prod<out T> { fun take(t: T) {} }
typealias Loop = Loop
class Acc(var n: Int) { operator fun plus(o: Acc) = Acc(n + o.n); operator fun plusAssign(o: Acc) { n += o.n } }
fun grow() { var a = Acc(1); a += Acc(2) }
val first: Int = second + 1
val second = 2
@DslMarker annotation class Html
@Html class Outer { fun outer() {} }
@Html class Inner
fun nest() { Outer().apply { Inner().apply { outer() } } }
fun <T> isErased(x: Any) = x is T
fun jump() { while (true) { break@nowhere } }
class Cyc<T : T>
@Target(AnnotationTarget.CLASS) annotation class OnlyClass
@OnlyClass fun annotated() {}
@RequiresOptIn annotation class Unstable
@Unstable fun unstable() = 1
fun usesUnstable() = unstable()
