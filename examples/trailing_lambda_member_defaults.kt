// A member/companion/object call whose middle parameters are defaulted
// function types binds a trailing lambda to the LAST parameter, with the
// gap parameters taking their defaults -- `observe({}) { work() }` must
// bind the first lambda to `readObserver` and the trailing one to `block`,
// never shifting the trailing lambda into `writeObserver`.

class Tracker {
    fun <T> observe(
        readObserver: ((Any) -> Unit)? = null,
        writeObserver: ((Any) -> Unit)? = null,
        block: () -> T,
    ): T {
        println("member ro=${readObserver != null} wo=${writeObserver != null}")
        return block()
    }

    companion object {
        fun <T> observeStatic(
            readObserver: ((Any) -> Unit)? = null,
            writeObserver: ((Any) -> Unit)? = null,
            block: () -> T,
        ): T {
            println("companion ro=${readObserver != null} wo=${writeObserver != null}")
            return block()
        }
    }
}

object TrackerObject {
    fun <T> observe(
        readObserver: ((Any) -> Unit)? = null,
        writeObserver: ((Any) -> Unit)? = null,
        block: () -> T,
    ): T {
        println("object ro=${readObserver != null} wo=${writeObserver != null}")
        return block()
    }
}

fun main() {
    println(Tracker().observe({}) { 1 })
    println(Tracker.observeStatic({}) { 2 })
    println(Tracker.Companion.observeStatic({}) { 3 })
    println(TrackerObject.observe({}) { 4 })
    println(Tracker().observe { 5 })
}
