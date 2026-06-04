class Box(val n: Int) { fun show(tag: String): String = "n=$n tag=$tag" }

fun memberStyle(block: Box.(String) -> Unit) { Box(5).block("hi") }
fun valueStyle(block: Box.(String) -> Unit) { block(Box(9), "yo") }
fun invokeStyle(block: Box.(String) -> String): String = block.invoke(Box(3), "x")
fun twoParams(block: Box.(String, Int) -> String): String = block(Box(1), "k", 42)

fun main() {
    memberStyle { s -> println(show(s)) }
    valueStyle { s -> println(show(s)) }
    println(invokeStyle { s -> show(s) })
    println(twoParams { a, b -> show(a) + " b=" + b })
}
