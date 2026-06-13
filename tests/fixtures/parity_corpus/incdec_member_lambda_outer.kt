class C {
    var x = 0
    fun run() { val f = { x++ }; f(); f() }
}
fun main() { val c = C(); c.run(); println(c.x) }
