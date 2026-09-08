// A companion-object property with a custom getter runs the getter on every
// read, even when the property also has a backing field: `get() = field++`
// returns and then advances the field, so successive reads see 1, 2, 3.
class Counter {
    companion object {
        var next: Int = 1
            get() = field++
    }
}

class Toggle {
    companion object {
        var flips = 0
        val state: String
            get() {
                flips++
                return if (flips % 2 == 1) "on" else "off"
            }
    }
}

fun main() {
    println(Counter.next)
    println(Counter.next)
    println(Counter.next)
    println(Toggle.state)
    println(Toggle.state)
    println(Toggle.flips)
}
