// MM3 — no out-of-thin-air: a read only ever observes a value some
// write produced (the initial value or an assigned one).
//> 0
//> 42
class Cell { var x: Int = 0 }
fun main() {
    val c = Cell()
    println(c.x)
    c.x = 42
    println(c.x)
}
