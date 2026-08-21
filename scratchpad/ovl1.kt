fun <R, T> (R.() -> T).run2(receiver: R, tag: String): T {
    println("receiver-form $tag")
    val b = this
    return receiver.b()
}

fun <P, T> ((P) -> T).run2(param: P, tag: String): T {
    println("param-form $tag")
    val b = this
    return b(param)
}

fun main() {
    val withRecv: String.() -> Int = { length }
    val withParam: (String) -> Int = { s -> s.length }
    println(withRecv.run2("abc", "r"))
    println(withParam.run2("abcd", "p"))
}
