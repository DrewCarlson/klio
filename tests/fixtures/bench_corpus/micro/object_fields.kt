// Hot ObjRef<InstanceData> path: instance field get/set in a tight
// loop, the most cache-unfriendly borrow site (a distinct cell per
// object). Stresses the per-cell borrow the refactor made atomic.
class Point(var x: Int, var y: Int) {
    fun step() { x += 1; y += x }
}
fun main() {
    val p = Point(0, 0)
    var i = 0
    while (i < 50000) {
        p.step()
        i += 1
    }
    println(p.y)
}
