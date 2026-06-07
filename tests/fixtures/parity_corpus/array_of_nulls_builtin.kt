// `arrayOfNulls<T>(size)` builds a size-`n` array of nulls that can
// then be populated by index.
fun main() {
    val a = arrayOfNulls<String>(3)
    println(a.size)
    println(a[0])
    a[1] = "x"
    println(a[1])
    println(a[2])

    val empty = arrayOfNulls<Int>(0)
    println(empty.size)
}
