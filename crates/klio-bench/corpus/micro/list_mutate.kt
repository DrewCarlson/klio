// Hot ObjRef<Vec<Value>> path: mutable-list append + indexed
// read/write in a tight loop. Stresses borrow/borrow_mut + Value
// clone, which the value-model refactor made atomic.
fun main() {
    val xs = ArrayList<Int>()
    var i = 0
    while (i < 20000) {
        xs.add(i)
        i += 1
    }
    var s = 0L
    var j = 0
    while (j < xs.size) {
        s += xs[j].toLong()
        xs[j] = xs[j] + 1
        j += 1
    }
    println(s)
}
