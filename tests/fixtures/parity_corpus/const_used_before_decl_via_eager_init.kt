// A top-level `const val` is a compile-time constant: it must be
// observable even when an earlier (in source order) top-level
// initializer constructs a class whose body reads a `const` declared
// later. `first`'s initializer runs before `SHIFT`'s declaration is
// reached, yet `Holder` must still see `SHIFT`.
val first: Int = Holder().packed
val second: Int = Holder().masked

class Holder {
    val packed: Int = 1 shl SHIFT
    val masked: Int = (1 shl SHIFT) - 1
}

private const val SHIFT = 4

fun main() {
    println(first)
    println(second)
    println(first + SHIFT)
}
