// A member extension declared inside a generic class returns the class's
// own type parameter. Kotlin types every call of it at that parameter's
// declared upper bound, resolved in the DECLARING scope — a caller whose
// own type parameter shadows the name with a different bound must not
// change the overload pick made on the returned value.
class Accumulator {
    operator fun plus(value: Number): String = "number:" + value
    operator fun plus(value: CharSequence): String = "chars:" + value
}

class Scope<T : Number>(private val value: T) {
    fun String.scopedValue(): T = value

    // The fn-level T here bounds to CharSequence; the returned value's
    // static type still comes from the CLASS parameter's bound (Number),
    // so `plus(Number)` wins.
    fun <T : CharSequence> pick(value: T): String =
        Accumulator() + "$value".scopedValue()
}

fun main() {
    println(Scope(4).pick("shadow"))
    println(Scope(2.5).pick("x"))
}
