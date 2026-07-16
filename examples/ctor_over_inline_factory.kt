// A bare constructor call inside the class's own body binds the constructor,
// never a same-named reified inline factory that happens to fit the arity —
// `Vec(arr, targetSize)` must not splice `Vec(size, init)`.
package examples.ctorfactory

class Vec<T>(var content: Array<T?>, var size: Int) {
    fun asList(): List<T?> = content.toList().subList(0, size)

    inline fun <reified R> mapNotNull(transform: (T) -> R?): Vec<R> {
        val size = size
        val arr = arrayOfNulls<R>(size)
        var targetSize = 0
        @Suppress("UNCHECKED_CAST")
        val items = content as Array<T>
        for (i in 0 until size) {
            val target = transform(items[i])
            if (target != null) {
                arr[targetSize++] = target
            }
        }
        return Vec(arr, targetSize)
    }
}

inline fun <reified T> Vec(capacity: Int = 16): Vec<T> =
    Vec(arrayOfNulls<T>(capacity), 0)

inline fun <reified T> Vec(size: Int, noinline init: (Int) -> T): Vec<T> {
    val arr = Array<Any?>(size, init)
    @Suppress("UNCHECKED_CAST")
    return Vec(arr as Array<T?>, size)
}

fun main() {
    val v = Vec<Int>(arrayOf(1, 2, 3, 4, 5), 5)
    val mapped = v.mapNotNull { item -> if (item == 5) null else item - 1 }
    println(mapped.asList())
    val fromFactory = Vec<String>(4)
    println(fromFactory.size)
}
