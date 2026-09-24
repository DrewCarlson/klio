// An extension on a function-typed receiver of either SHAPE: `R.() -> T`
// hands its argument to the lambda as the receiver, `(P) -> T` as the value
// parameter, though a lambda of either shape is one runtime object. The two
// shapes are the same type for overloading (kotlinc reports an extension
// family overloaded on them as conflicting), so each shape's extension has
// its own name.
//
// Run with: klio run examples/function_type_receiver_overload.kt

fun <R, T> (R.() -> T).describe(receiver: R): String {
    val block = this
    return "receiver-form(" + receiver.block() + ")"
}

fun <P, T> ((P) -> T).describeParam(param: P): String {
    val block = this
    return "param-form(" + block(param) + ")"
}

fun <V, T> throughValueParam(value: V, block: (V) -> T): String = block.describeParam(value)

fun <V, T> throughReceiver(value: V, block: V.() -> T): String = block.describe(value)

// Two value parameters keep their own arity apart from the receiver form.
fun <A, B, T> (A.(B) -> T).describe2(receiver: A, second: B): String {
    val block = this
    return "receiver2(" + receiver.block(second) + ")"
}

fun <A, B, T> ((A, B) -> T).describe2Params(first: A, second: B): String {
    val block = this
    return "param2(" + block(first, second) + ")"
}

fun <A, B, T> twoThroughParams(a: A, b: B, block: (A, B) -> T): String = block.describe2Params(a, b)

fun <A, B, T> twoThroughReceiver(a: A, b: B, block: A.(B) -> T): String = block.describe2(a, b)

fun main() {
    println(throughValueParam("abc") { s -> s.length })
    println(throughReceiver("abcd") { length })
    println(twoThroughParams("ab", 2) { s, n -> s.repeat(n) })
    println(twoThroughReceiver("cd", 3) { n -> repeat(n) })
}
