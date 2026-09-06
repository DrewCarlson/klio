// A constructor reference is a callable: `::A` for a top-level or local
// class constructs `A`; `Outer::Inner` for an inner class is the unbound
// form that takes the outer instance as its first argument, and
// `outer::Inner` binds it. An argument written `as Any` never fits a
// member whose parameter has a concrete class type, so
// `zs.contains(x as Any)` on a `Collection<Z>` implementation is a
// candidate for the `Iterable<T>.contains` extension, never the member.
class Outer(val tag: String) {
    inner class Inner(val n: Int) {
        fun describe() = "$tag#$n"
    }
}

fun main() {
    class Local(val v: Int) {
        val doubled = v * 2
    }
    val make = ::Local
    println(make(21).doubled)
    println((::Local).let { it(4) }.doubled)

    val unbound = Outer::Inner
    println(unbound(Outer("u"), 1).describe())
    val outer = Outer("b")
    val bound = outer::Inner
    println(bound(2).describe())
    println(listOf(3, 4).map(outer::Inner).map { it.describe() })
}
