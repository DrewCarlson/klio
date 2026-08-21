fun <R, T> (R.() -> T).apply2(receiver: R): String {
    val b = this
    return "receiver-form:" + receiver.b()
}

fun <P, T> ((P) -> T).apply2(param: P): String {
    val b = this
    return "param-form:" + b(param)
}

fun <V, T> viaParam(value: V, block: (V) -> T): String = block.apply2(value)
fun <V, T> viaReceiver(value: V, block: V.() -> T): String = block.apply2(value)

fun main() {
    println(viaParam("abc") { s -> s.length })
    println(viaReceiver("abcd") { length })
}
