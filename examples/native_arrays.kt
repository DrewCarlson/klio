// Arrays compiled to C. A primitive array is a packed scalar buffer, so an
// `IntArray` holds int32 elements and an indexed read is a load rather than an
// unbox; the emitter knows the element kind from the array's own type name and
// names it to the runtime. A reference `Array<T>` holds boxed values. Indexing
// checks its bounds and reports the range Kotlin reports.
fun sum(a: IntArray): Int {
    var s = 0
    var i = 0
    while (i < a.size) {
        s = s + a[i]
        i = i + 1
    }
    return s
}

fun scale(a: DoubleArray, k: Double) {
    var i = 0
    while (i < a.size) {
        a[i] = a[i] * k
        i = i + 1
    }
}

fun main() {
    val a = IntArray(4)
    a[0] = 10
    a[1] = 20
    a[2] = 30
    a[3] = 40
    println(a.size)
    println(a[2])
    println(sum(a))

    // A sized array starts at its element type's zero.
    val zeros = IntArray(3)
    println(sum(zeros))

    val b = intArrayOf(1, 2, 3)
    println(sum(b))

    val d = doubleArrayOf(1.5, 2.5)
    scale(d, 2.0)
    println(d[0])
    println(d[1])

    val longs = longArrayOf(1L, 2L, 3L)
    println(longs[2])

    // A reference array holds whatever it is given.
    val names = arrayOf("x", "y", "z")
    println(names.size)
    println(names[1])
    names[1] = "q"
    println(names[1])
}
