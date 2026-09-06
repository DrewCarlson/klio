// An annotation class can be instantiated like any class, and its
// instances behave by value: `equals` holds when every parameter is
// equal (arrays by content, floating-point values by bit pattern, so NaN
// equals NaN and 0.0 differs from -0.0), `hashCode` folds each parameter
// as `(127 * name.hashCode()) xor value.hashCode()` with arrays hashed by
// content, and `toString` renders `@Name(param=value, ...)` with nested
// annotations and arrays rendered inline. Defaults apply as usual.
annotation class Tag(val name: String, val weight: Int = 1)
annotation class Marks(val tag: Tag, val values: IntArray = [1, 2], val ratio: Double = 0.5)

fun main() {
    val a = Tag("alpha", 3)
    val b = Tag("alpha", 3)
    val c = Tag("beta")
    println(a == b)
    println(a == c)
    println(a.hashCode() == b.hashCode())
    println(a.hashCode() == c.hashCode())
    println(a)
    println(c)
    println(c.weight)

    val any1: Any = a
    val any2: Any = b
    println(any1.equals(any2))
    println(any1.hashCode() == any2.hashCode())

    val m1 = Marks(Tag("t"), intArrayOf(4, 5), Double.NaN)
    val m2 = Marks(Tag("t"), intArrayOf(4, 5), Double.NaN)
    val m3 = Marks(Tag("t"), intArrayOf(4, 6), Double.NaN)
    println(m1 == m2)
    println(m1 == m3)
    println(m1.hashCode() == m2.hashCode())
    println(Marks(Tag("z"), intArrayOf(), 0.0) == Marks(Tag("z"), intArrayOf(), -0.0))
    println(Marks(Tag("t")))
    println(Tag("x").hashCode() == (127 * "name".hashCode() xor "x".hashCode()) + (127 * "weight".hashCode() xor 1))
}
