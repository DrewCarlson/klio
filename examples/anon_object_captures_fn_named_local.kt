// A local whose name matches a top-level extension function still
// value-captures into an anonymous object when it is NOT callable:
// `read` here is a MutableList, so `read.add(...)` inside the object's
// method lambda reads the local, never the `Reader.read` extension.

class Reader
fun Reader.read(n: Int): Int = n

class Wraps(val readObserver: ((Any) -> Unit)?)

interface Obs {
    fun onPre(flag: Boolean): Wraps?
}

fun useObs(o: Obs) {
    val w = o.onPre(true)
    w?.readObserver?.invoke("state")
}

fun main() {
    val read = mutableListOf<Pair<Any, Boolean>>()
    useObs(
        object : Obs {
            override fun onPre(flag: Boolean): Wraps {
                return Wraps(readObserver = { read.add(it to true) })
            }
        }
    )
    println(read)
    println(Reader().read(5))
}
