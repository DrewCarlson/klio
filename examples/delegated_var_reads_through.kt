// `var x by D` reads THROUGH the delegate on every read — the value is not
// cached at the declaration — so a stateful delegate hands back its current
// value, and a read inside a lambda sees writes made after the lambda was made.

class Counter {
    var reads = 0
    private var value = 0

    operator fun getValue(thisRef: Any?, property: Any?): Int {
        reads = reads + 1
        return value
    }

    operator fun setValue(thisRef: Any?, property: Any?, newValue: Int) {
        value = newValue
    }
}

fun main() {
    val delegate = Counter()
    var count by delegate

    println("start=" + count)
    count = 7
    println("after write=" + count)
    println("template=$count")

    val show = { "captured=" + count }
    count = 9
    println(show())
    println("reads=" + delegate.reads)
}
