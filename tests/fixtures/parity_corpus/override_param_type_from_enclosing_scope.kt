// A parameter type written unqualified inside a nested class names the
// ENCLOSING class's member, so `Slot` in `Registry.Entry` is `Registry.Slot`.
// The virtual-slot linker compares an override's parameter types against the
// base declaration's, and it resolved an unqualified name only against the
// owner itself. `Registry.Entry.dropSlot(s: Slot)` and
// `Tagged.dropSlot(s: Registry.Slot)` therefore compared unequal, `Tagged`'s
// declaration was not recognised as an override, and a class inheriting the
// member from both an abstract base and `Tagged` kept the base's behaviour.
interface Registry {
    interface Slot

    fun dropSlot(s: Slot): String

    interface Entry : Registry {
        val slot: Slot
        override fun dropSlot(s: Slot): String = if (s === slot) "base-empty" else "base-kept"
    }
}

// Overrides the inherited default, and spells the parameter type qualified.
interface Tagged : Registry.Entry {
    override fun dropSlot(s: Registry.Slot): String = if (s === slot) "tagged-empty" else "tagged-kept"
}

abstract class BaseEntry(override val slot: Registry.Slot) : Registry.Entry

object TheSlot : Registry.Slot
object OtherSlot : Registry.Slot

// Inherits `dropSlot` from BaseEntry (which carries Entry's default) AND from
// Tagged (which overrides it). Tagged's override is the more specific one.
class Both : BaseEntry(TheSlot), Tagged

class Direct : Tagged {
    override val slot: Registry.Slot = TheSlot
}

fun main() {
    val both: Registry = Both()
    println(both.dropSlot(TheSlot))
    println(both.dropSlot(OtherSlot))

    val direct: Registry = Direct()
    println(direct.dropSlot(TheSlot))

    // Also reachable through the intermediate interface's own static type.
    val entry: Registry.Entry = Both()
    println(entry.dropSlot(TheSlot))
}
