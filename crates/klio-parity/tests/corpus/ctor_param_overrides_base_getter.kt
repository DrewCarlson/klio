// A constructor-parameter `override val` on a subclass overrides an `open val`
// with a custom getter on the base: reading the property must return the
// subclass's stored field, not invoke the inherited base getter.
abstract class Base {
    open val tag: String? get() = null
    open val size: Long get() = 0
    open val label: String get() = "base"
}

class Sub(
    override val tag: String,
    private val data: String,
) : Base() {
    override val size: Long get() = data.length.toLong()
    fun render(): String = "$tag/$size/$label/$data"
}

// A deeper chain: the stored override sits one level above the instance class.
abstract class Mid : Base() {
    override val label: String = "mid"
}
class Leaf(override val tag: String) : Mid()

fun main() {
    val s = Sub("hi", "abcd")
    println(s.tag)
    println(s.size)
    println(s.label)
    println(s.render())

    val b: Base = s
    println(b.tag)
    println(b.label)

    val leaf = Leaf("x")
    println(leaf.tag)
    println(leaf.label)
}
