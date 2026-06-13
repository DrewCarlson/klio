fun main() {
    var x = 0
    val f = { x++ }
    f(); f()
    println(x)
}
