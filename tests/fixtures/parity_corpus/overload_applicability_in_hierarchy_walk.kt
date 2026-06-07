// A same-named member found earlier in the receiver's class
// hierarchy is dispatched only when it is *applicable* to the
// argument. `Sub` declares a narrowing `operator fun plus(Sub)`
// (mirrors the deprecated `CoroutineDispatcher.plus(CoroutineDispatcher)`,
// an overload — not an override — of an inherited wider `plus`).
// Calling `sub + nonSub` must skip that narrower overload and use the
// inherited `Base.plus(Base)`, not silently return the argument.

open class Base {
    operator fun plus(other: Base): Base = Combined(this, other)
}

class Combined(val a: Base, val b: Base) : Base()

class Sub : Base() {
    operator fun plus(other: Sub): Sub = other
}

class Other : Base()

fun main() {
    val s = Sub()
    val o = Other()

    val r = s + o
    println(r === o)
    println(r === s)
    println(r is Combined)

    val s2 = Sub()
    val r2 = s + s2
    println(r2 === s2)
    println(r2 === s)

    val r3 = Other() + Other()
    println(r3 is Combined)
}
