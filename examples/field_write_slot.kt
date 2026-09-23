// A write to a plain stored property goes straight to its layout slot, the
// mirror of the read. "Plain" for a write is not the same question as for a
// read: a property can read straight from its slot while its setter runs code,
// so the write claim needs the setter to be absent as well as the getter.
//
// Run with: klio run examples/field_write_slot.kt

class Counter(var hits: Int) {
    var misses: Int = 0

    // A custom setter runs on every write, so this one is never a bare store.
    var clamped: Int = 0
        set(v) {
            field = if (v < 0) 0 else v
        }

    // A getter with a stored backing field: reads run the getter, writes store.
    var raw: Int = 1
        get() = field * 10

    fun record(hit: Boolean) {
        if (hit) hits = hits + 1 else misses = misses + 1
    }
}

fun main() {
    val c = Counter(0)
    c.record(true)
    c.record(false)
    c.record(true)
    c.hits = c.hits + 10
    println("hits=${c.hits} misses=${c.misses}")
    c.clamped = -5
    println("clamped=${c.clamped}")
    c.clamped = 7
    println("clamped=${c.clamped}")
    c.raw = 3
    println("raw=${c.raw}")
}
