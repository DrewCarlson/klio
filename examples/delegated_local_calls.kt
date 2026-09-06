// A delegated local is read through its delegate on every use, whichever
// form the use takes: a plain read, a call of the value it yields, a read
// inside a lambda, and a read or call inside an anonymous object's method
// that closes over it. The delegate object itself is never observed.
import kotlin.reflect.KProperty

class Slot<T>(private var value: T) {
    var reads = 0
    operator fun getValue(thisRef: Any?, property: KProperty<*>): T {
        reads++
        return value
    }
    operator fun setValue(thisRef: Any?, property: KProperty<*>, newValue: T) {
        value = newValue
    }
}

interface Greeter {
    fun greet(): String
}

fun main() {
    val slot = Slot<() -> String>({ "hello" })
    val handler by slot
    println(handler())
    val viaLambda = { handler() + "!" }
    println(viaLambda())
    val greeter = object : Greeter {
        override fun greet() = handler() + " from object"
    }
    println(greeter.greet())

    val counter = Slot(1)
    var count by counter
    count += 2
    val show = { "count=$count" }
    count++
    println(show())
    println("reads=${slot.reads} counterReads=${counter.reads}")
}
