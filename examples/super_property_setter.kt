// `super.prop = value` reaches the SUPERCLASS accessor: an overriding setter
// that writes through `super` must not re-enter itself.

open class Counter {
    open var count: Int = 0
    open val label: String
        get() = "counter"
}

class LoggingCounter : Counter() {
    var writes = 0
    override var count: Int
        get() = super.count
        set(value) {
            writes = writes + 1
            super.count = value
        }
    override val label: String
        get() = "logging(" + super.label + ")"
}

fun main() {
    val c = LoggingCounter()
    c.count = 5
    c.count = 7
    println("count=" + c.count + " writes=" + c.writes)
    println("label=" + c.label)
}
