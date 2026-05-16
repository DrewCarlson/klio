// Hot ObjRef<Vec<(Value,Value)>> path: mutable-map put then get in
// a loop. Stresses the map cell borrow + key/value Value clones.
fun main() {
    val m = HashMap<Int, Int>()
    var i = 0
    while (i < 4000) {
        m[i] = i * 2
        i += 1
    }
    var s = 0L
    var j = 0
    while (j < 4000) {
        s += (m[j] ?: 0).toLong()
        j += 1
    }
    println(s)
}
