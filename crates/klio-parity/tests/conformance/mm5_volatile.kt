// MM5 — @Volatile. Single-threaded reduction: a @Volatile var
// behaves exactly as a plain var (read-modify-write is visible in
// program order). The threaded guarantee (total order, no
// reordering) is exercised by the threaded suite once threads land.
//> 0
//> 42
//> 43
class Flag {
    @Volatile var v: Int = 0
}
fun main() {
    val f = Flag()
    println(f.v)
    f.v = 42
    println(f.v)
    f.v += 1
    println(f.v)
}
