// `super.<prop>` in an overriding property getter dispatches the
// base getter via the parent chain, never `this.<prop>` (which would
// re-enter the override and recurse forever). Mirrors upstream
// `AbstractCoroutine.isActive get() = super.isActive`.

open class Base {
    open val v: Int get() = 42
    open val w: String get() = "base"
    open val tag: String = "stored"
}

open class Mid : Base() {
    override val v: Int get() = super.v + 1
}

class Sub : Mid() {
    override val v: Int get() = super.v * 10
    override val w: String get() = super.w + "-sub"
    override val tag: String get() = super.tag + "!"
}

fun main() {
    val s = Sub()
    println(s.v)
    println(s.w)
    println(s.tag)
    val m: Base = Mid()
    println(m.v)
}
