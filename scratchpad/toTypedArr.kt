interface Src { fun tag(): String }
class S(val n: Int) : Src { override fun tag() = "S$n" }

inline fun <reified T> pack(items: Iterable<T>): Array<T> = items.toList().toTypedArray()

// mirror combine's Iterable overload: inline, reified, block body, local val
inline fun <reified T, R> useIterable(items: Iterable<T>, transform: (Array<T>) -> R): R {
    val arr = items.toList().toTypedArray()
    return transform(arr)
}

fun main() {
    val a = S(1); val b = S(2)
    val arr = pack(listOf(a, b))
    println("size=" + arr.size)
    println("elem0 tag=" + arr[0].tag())
    for (i in 0 until arr.size) println("i=$i tag=" + arr[i].tag())

    val r = useIterable(listOf(a, b)) { xs -> xs[0].tag() + xs[1].tag() }
    println("useIterable=" + r)

    // reified through a generic extension member, like combineLatest's override
    println("viaMember=" + Holder().go(a, b))
}

class Holder {
    fun <T1 : Src, R> go(x: T1, y: T1): String {
        return useIterable(listOf(x, y)) { xs -> xs[0].tag() + "," + xs[1].tag() }
    }
}
