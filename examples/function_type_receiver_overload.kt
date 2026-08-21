// An extension family overloaded on the SHAPE of a function-typed receiver
// resolves against the receiver's declared type: `R.() -> T` and `(P) -> T`
// are different types even though a lambda of either shape is one runtime
// object. The overload a call binds decides whether the lambda's argument
// arrives as its receiver or as its value parameter.
//
// Run with: klio run examples/function_type_receiver_overload.kt

fun <R, T> (R.() -> T).describe(receiver: R): String {
    val block = this
    return "receiver-form(" + receiver.block() + ")"
}

fun <P, T> ((P) -> T).describe(param: P): String {
    val block = this
    return "param-form(" + block(param) + ")"
}

fun <V, T> throughValueParam(value: V, block: (V) -> T): String = block.describe(value)

fun <V, T> throughReceiver(value: V, block: V.() -> T): String = block.describe(value)

// Two value parameters keep their own arity apart from the receiver form.
fun <A, B, T> (A.(B) -> T).describe2(receiver: A, second: B): String {
    val block = this
    return "receiver2(" + receiver.block(second) + ")"
}

fun <A, B, T> ((A, B) -> T).describe2(first: A, second: B): String {
    val block = this
    return "param2(" + block(first, second) + ")"
}

fun <A, B, T> twoThroughParams(a: A, b: B, block: (A, B) -> T): String = block.describe2(a, b)

fun <A, B, T> twoThroughReceiver(a: A, b: B, block: A.(B) -> T): String = block.describe2(a, b)

fun main() {
    println(throughValueParam("abc") { s -> s.length })
    println(throughReceiver("abcd") { length })
    println(twoThroughParams("ab", 2) { s, n -> s.repeat(n) })
    println(twoThroughReceiver("cd", 3) { n -> repeat(n) })
}
