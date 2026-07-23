class Box(val n: Int) { fun show(tag: String): String = "n=$n tag=$tag" }
class AdaptReceiver(val base: Int)

class AdaptOuter(val base: Int) {
    fun run(): Int {
        val plain: (AdaptReceiver, Int) -> Int = { receiver, value ->
            base + receiver.base + value
        }
        val adapted: AdaptReceiver.(Int) -> Int = plain
        return AdaptReceiver(3).adapted(4)
    }

    fun runNamed(): Int {
        fun plain(receiver: AdaptReceiver, value: Int): Int =
            receiver.base + value
        val adapted: AdaptReceiver.(Int) -> Int = ::plain
        return AdaptReceiver(3).adapted(4)
    }
}

fun memberStyle(block: Box.(String) -> Unit) { Box(5).block("hi") }
fun valueStyle(block: Box.(String) -> Unit) { block(Box(9), "yo") }
fun invokeStyle(block: Box.(String) -> String): String = block.invoke(Box(3), "x")
fun twoParams(block: Box.(String, Int) -> String): String = block(Box(1), "k", 42)
fun ignoresReceiver(block: Box.(Int) -> Int): Int = block(Box(7), 4)

fun anonymousReceiver(): Int {
    val block = fun String.(value: Int): Int = value + length
    return block("abc", 4)
}

fun main() {
    memberStyle { s -> println(show(s)) }
    valueStyle { s -> println(show(s)) }
    println(invokeStyle { s -> show(s) })
    println(twoParams { a, b -> show(a) + " b=" + b })
    println(ignoresReceiver { value -> value + 1 })
    println(anonymousReceiver())
    println(AdaptOuter(10).run())
    println(AdaptOuter(10).runNamed())
}
