// An enum class has a natural ordering: its declaration order. Entries are
// Comparable, so they sort, compare, and answer `compareValues` — which the
// generic comparison helpers route through.
//
// Entries of DIFFERENT enum classes share no ordering, so nothing compares
// them; only entries of the same enum do.
//
// Run with: klio run examples/enum_natural_order.kt

enum class Priority { LOW, MEDIUM, HIGH }

enum class Suit { CLUBS, HEARTS }

data class Task(val name: String, val priority: Priority)

fun main() {
    val low = Priority.LOW
    val high = Priority.HIGH

    println("compareTo  = " + low.compareTo(high))
    println("less       = " + (low < high))
    println("greater    = " + (high > low))
    println("equalSelf  = " + high.compareTo(high))

    println("sorted     = " + listOf(Priority.HIGH, Priority.LOW, Priority.MEDIUM).sorted())
    println("descending = " + listOf(Priority.LOW, Priority.HIGH).sortedDescending())
    println("min/max    = " + minOf(high, low) + "/" + maxOf(high, low))

    // The generic comparison helpers order entries the same way.
    println("compareVal = " + compareValues(low, high))
    println("byKey      = " + listOf(
        Task("b", Priority.HIGH),
        Task("a", Priority.LOW),
    ).sortedWith(compareBy { it.priority }).map { it.name })

    // Ordering follows declaration order, not the entry name.
    println("byName?    = " + (Priority.MEDIUM < Priority.HIGH))
    println("ordinals   = " + Priority.entries.map { it.ordinal })

    // Every enum is Comparable, so the generic `Comparable` extensions apply.
    println("coerceAtMost  = " + high.coerceAtMost(Priority.MEDIUM))
    println("coerceAtLeast = " + low.coerceAtLeast(Priority.MEDIUM))
    println("coerceIn      = " + high.coerceIn(low, Priority.MEDIUM))
    println("inRange       = " + (Priority.MEDIUM in low..high))

    // A different enum is simply a different ordering.
    println("otherEnum  = " + listOf(Suit.HEARTS, Suit.CLUBS).sorted())
}
