// Lazy object / companion initialization: an object initializes at its
// first access (never at program start), exactly once; a companion also
// initializes at the first instantiation of its owning class; an object
// the program never references never initializes; object-literal init
// blocks interleave with property initializers in declaration order; an
// init failure surfaces at the access site as
// FileFailedToInitializeException and is never retried.

object NeverTouched {
    init { println("never-touched-init (must not print)") }
}

object Settings {
    val level = run { println("settings: level"); 3 }
    init { println("settings: init level=$level") }
    val label = run { println("settings: label"); "ready" }
}

class Engine {
    init { println("engine: instance init") }

    companion object {
        val defaultPower = run { println("engine: companion prop"); 90 }
        init { println("engine: companion init") }
    }
}

object Broken {
    val pieces = mutableListOf("a")
    init { if (pieces.size == 1) throw IllegalStateException("snapped") }
}

fun traced(label: String, v: Int): Int {
    println(label)
    return v
}

fun main() {
    println("main: start")

    println("main: settings -> " + Settings.label + "/" + Settings.level)
    println("main: settings again -> " + Settings.level)

    val e = Engine()
    println("main: engine built " + (e is Engine) + " power=" + Engine.defaultPower)

    val probe = object {
        val first = traced("anon: first", 1)
        init { println("anon: init first=$first") }
        val second = traced("anon: second", 2)
    }
    println("main: anon sum=" + (probe.first + probe.second))

    val attempts = ArrayList<String>()
    repeat(2) {
        try {
            println(Broken.pieces)
        } catch (t: Throwable) {
            attempts.add(t::class.simpleName + "/" + (t.cause?.let { c -> c::class.simpleName } ?: "none"))
        }
    }
    println("main: broken -> " + attempts)

    println("main: end")
}
