// A function-typed parameter does NOT shadow a same-named function for a call it
// cannot accept. A trailing lambda binds the callee's LAST parameter, so a
// parameter whose own last parameter is not a function type is not the target of
// `name { ... }`. This is `Flow.map`'s shape, whose `crossinline transform` is
// named after the `transform` operator its body calls: the outer
// `transform { value -> ... }` is the OPERATOR, only the inner `transform(value)`
// is the parameter. Binding the parameter outside passed the operator's own
// lambda in as the element, so the caller's `it` was a closure.

class Flw<T>(val items: List<T>)

fun <T, R> Flw<T>.transform(block: (T) -> R): Flw<R> = Flw(items.map { block(it) })

inline fun <T, R> Flw<T>.mp(crossinline transform: (T) -> R): Flw<R> =
    transform { value -> transform(value) }

fun main() {
    println(Flw(listOf(1, 2)).mp { it * 10 }.items)
}
