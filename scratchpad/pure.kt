class Box(val n: Int)

fun mk(): Box = Box(1)
fun box(body: () -> Int): Box = Box(body())

fun main() {
    val box = mk()                 // ordinary CALL initializer, not a ctor
    println("call  = " + box { 7 }.n)
    println("value = " + box.n)
}
