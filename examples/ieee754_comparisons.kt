// Floating-point comparisons follow the static type. On `Double`/`Float`
// operands, including a value smart-cast to one, `==` and `<` are the
// IEEE 754 operators: `-0.0 == 0.0` and `NaN != NaN`, and a Double meets
// a Float as a Double. On a boxed or `Comparable<Double>` operand — an
// `Any`, a generic value, or a `Comparable` cast — the members apply:
// `equals` by representation (`-0.0` differs from `0.0`, NaN equals NaN)
// and `compareTo`'s total order (`-0.0 < 0.0`, NaN greatest). Mixed
// numeric `compareTo` converts to Double and uses the same total order.
fun ieee(a: Double, b: Double) = a == b
fun boxed(a: Any, b: Any) = a == b
fun cast(a: Any, b: Double) = (a as Comparable<Double>) >= b
fun smart(a: Any?, b: Any?) = a is Double && b is Double && a == b
fun mixed(x: Any, y: Any) = x is Double && y is Float && x != y
fun <T : Comparable<Double>> generic(a: T, b: Double) = a < b

fun main() {
    println(ieee(-0.0, 0.0))
    println(ieee(Double.NaN, Double.NaN))
    println(boxed(-0.0, 0.0))
    println(boxed(Double.NaN, Double.NaN))
    println(smart(-0.0, 0.0))
    println(smart(Double.NaN, Double.NaN))
    println(mixed(0.0, -0.0F))
    println(cast(-0.0, 0.0))
    println(generic(-0.0, 0.0))
    println((-0.0).equals(0.0))
    println(Double.NaN.equals(Double.NaN))
    println((-0.0).compareTo(0.0))
    println(0.compareTo(-0.0))
    println(0.compareTo(Double.NaN))
    println(0.toByte().compareTo(-0.0F))
    println(0.0F.compareTo(-0.0))
}
