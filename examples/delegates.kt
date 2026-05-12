import kotlin.properties.Delegates

class Box(val first: String, val last: String) {
    val full: String
        get() = "$first $last"
    var counter: Int = 0
        set(value) {
            if (value >= 0) {
                field = value
            }
        }
}

var computeCalls = 0

fun heavy(): Int {
    computeCalls += 1
    return 42
}

val cached: Int by lazy { heavy() }

var watched: String by Delegates.observable("initial") { _, old, new ->
    println("watched: $old -> $new")
}

var required: String by Delegates.notNull<String>()

class LoggingDelegate(var v: Int) {
    operator fun getValue(thisRef: Any?, prop: Any?): Int = v
    operator fun setValue(thisRef: Any?, prop: Any?, value: Int) {
        println("logged set = $value")
        v = value
    }
}

var counted: Int by LoggingDelegate(0)

fun main() {
    val b = Box("Ada", "Lovelace")
    println(b.full)
    b.counter = 3
    println(b.counter)
    b.counter = -7
    println(b.counter)

    println("computeCalls before: $computeCalls")
    println(cached)
    println(cached)
    println("computeCalls after: $computeCalls")

    watched = "second"
    watched = "third"
    println(watched)

    try {
        println(required)
    } catch (e: IllegalStateException) {
        println("caught: ${e.message}")
    }
    required = "ready"
    println(required)

    counted = 1
    counted = 99
    println(counted)
}
