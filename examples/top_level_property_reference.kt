// Unbound top-level property references (`::name`) produce a `KProperty0`
// (or `KMutableProperty0` for a `var`). `get()` reads the referenced
// top-level property — a stored `val`/`var`, or one declared with only a
// custom `get()` accessor — and `set(v)` writes a `var` through to the real
// property. `invoke()` is the `() -> V` form of `get()`.

import kotlin.reflect.KProperty0
import kotlin.reflect.KMutableProperty0

val pi: Double get() = 3.14

val label = "kt"

var counter = 7

fun show(prop: KProperty0<Int>): Int = prop.get()

fun main() {
    // Custom-getter top-level val read through KProperty0.
    val piRef: KProperty0<Double> = ::pi
    println(piRef.get())
    println(piRef.name)

    // Stored top-level val, read via get() and the invoke() form.
    val labelRef: KProperty0<String> = ::label
    println(labelRef.get())
    println(labelRef.invoke())

    // Stored top-level var: get(), set() write-through, and re-read.
    val counterRef: KMutableProperty0<Int> = ::counter
    println(counterRef.get())
    counterRef.set(9)
    println(counterRef.get())
    println(counter)

    // A reference passed where a KProperty0 is expected.
    println(show(::counter))
}
