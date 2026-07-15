// A scalar typealias is transparent for overload resolution: a Long argument
// matches a parameter declared with a `= Long` alias, even when the method is
// overloaded with a zero-argument sibling of the same name.

typealias Id = Long

abstract class Record {
    abstract fun copy(): Record
    open fun copy(id: Id): Record = copy().also { it.recordId = id }
    var recordId: Id = 0
}

class IntRecord(var v: Int) : Record() {
    override fun copy(): Record = IntRecord(v)
    override fun copy(id: Id): Record = IntRecord(v).also { it.recordId = id }
}

fun <T : Record> T.duplicate(): T {
    @Suppress("UNCHECKED_CAST")
    return copy(999L) as T
}

fun main() {
    val r = IntRecord(7).duplicate()
    println("recordId=" + r.recordId)
}
