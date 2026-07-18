// A block-body property getter whose nested (non-inline) lambda mutates a
// local `var` must box that var into a shared cell, exactly as a function
// body does. Otherwise the write lands on a transient copy (plain assign is
// lost) or misroutes a compound assign to `Int.plusAssign` (which does not
// exist). This mirrors androidx SlotTable's `slotsSize`/`groupSize` getters,
// which sum a counter inside a `traverseGroup { ... }` callback.

class Source(private val values: List<Int>) {
    fun each(body: (Int) -> Unit) {
        for (v in values) body(v)
    }
}

class Report(private val source: Source) {
    // Plain reassign of a captured var inside the getter's lambda.
    val total: Int
        get() {
            var acc = 0
            source.each { acc = acc + it }
            return acc
        }

    // Compound assign (`+=`) of a captured var, with an early return@label
    // guard before it — the shape SlotTable.slotsSize uses.
    val filteredTotal: Int
        get() {
            var acc = 0
            source.each {
                if (it < 0) return@each
                acc += it
            }
            return acc
        }

    // Postfix increment of a captured var inside the getter's lambda.
    val positiveCount: Int
        get() {
            var count = 0
            source.each { if (it > 0) count++ }
            return count
        }
}

fun main() {
    val report = Report(Source(listOf(3, -2, 5, 0, 4)))
    println("total=${report.total}")
    println("filteredTotal=${report.filteredTotal}")
    println("positiveCount=${report.positiveCount}")
}
