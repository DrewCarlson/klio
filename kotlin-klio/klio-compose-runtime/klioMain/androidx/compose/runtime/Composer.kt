// klio's replacement for the Compose compiler-plugin Composer + SlotTable.
//
// Upstream's Composer drives a gap-buffer SlotTable with positional keys the
// compiler emits. klio has no plugin: the interpreter brackets every
// `@Composable` call with `startGroup(callSiteKey)` / `endGroup()` (see
// src/interp_ir/vm/compose.zig + host_call_func.zig), and `remember` consumes
// slots from the current group via `rememberedValue` / `updateRememberedValue` /
// `changed`. The slot store here is a tree of group nodes keyed by the
// interpreter-supplied positional key (disambiguated per-occurrence so a
// composable called N times under one parent gets N distinct groups), each node
// holding an ordered slot list with a per-pass cursor — the positional-memo
// model, minus the gap buffer.

package androidx.compose.runtime

public interface Composer {
    /** Enter the positional group identified by [key] under the current group. */
    public fun startGroup(key: Long)

    /** Leave the current group. */
    public fun endGroup()

    /** The slot at the current cursor (advancing it); [Composer.Empty] if unset. */
    public fun rememberedValue(): Any?

    /** Overwrite the slot most recently returned by [rememberedValue]. */
    public fun updateRememberedValue(value: Any?)

    /** Consume a slot comparing [value] to its previous content; true if it differs. */
    public fun changed(value: Any?): Boolean

    public companion object {
        /** Sentinel for an unwritten slot — distinct from any user value (incl. null). */
        public val Empty: Any = EmptySlot
    }
}

private object EmptySlot {
    override fun toString(): String = "Composer.Empty"
}

/** One positional group: an ordered slot list plus keyed child groups. */
internal class GroupNode(@JvmField val key: Long) {
    @JvmField val slots: ArrayList<Any?> = ArrayList()
    @JvmField val children: HashMap<Long, GroupNode> = HashMap()
    @JvmField var slotCursor: Int = 0
    @JvmField val childOccurrences: HashMap<Long, Int> = HashMap()

    /** Reset the per-composition-pass cursors before (re)entering this group. */
    fun enterPass() {
        slotCursor = 0
        childOccurrences.clear()
    }
}

internal class KlioComposer : Composer {
    private val root = GroupNode(0L)
    private val stack = ArrayList<GroupNode>()

    init {
        stack.add(root)
    }

    private fun current(): GroupNode = stack[stack.size - 1]

    /** Begin a fresh composition pass at the root group. */
    fun beginCompose() {
        stack.clear()
        stack.add(root)
        root.enterPass()
    }

    fun endCompose() {
        // Group balance is the interpreter's responsibility (startGroup/endGroup
        // are emitted around every @Composable body); nothing to settle here yet.
    }

    override fun startGroup(key: Long) {
        val parent = current()
        val occ = parent.childOccurrences[key] ?: 0
        parent.childOccurrences[key] = occ + 1
        val cid = key * 1000003L + occ.toLong()
        var node = parent.children[cid]
        if (node == null) {
            node = GroupNode(key)
            parent.children[cid] = node
        }
        node.enterPass()
        stack.add(node)
    }

    override fun endGroup() {
        if (stack.size > 1) stack.removeAt(stack.size - 1)
    }

    override fun rememberedValue(): Any? {
        val g = current()
        val v: Any?
        if (g.slotCursor < g.slots.size) {
            v = g.slots[g.slotCursor]
        } else {
            g.slots.add(Composer.Empty)
            v = Composer.Empty
        }
        g.slotCursor = g.slotCursor + 1
        return v
    }

    override fun updateRememberedValue(value: Any?) {
        val g = current()
        val idx = g.slotCursor - 1
        if (idx >= 0 && idx < g.slots.size) g.slots[idx] = value
    }

    override fun changed(value: Any?): Boolean {
        val g = current()
        val idx = g.slotCursor
        val prev: Any?
        if (idx < g.slots.size) {
            prev = g.slots[idx]
        } else {
            g.slots.add(Composer.Empty)
            prev = Composer.Empty
        }
        g.slotCursor = g.slotCursor + 1
        return if (prev != value) {
            g.slots[idx] = value
            true
        } else {
            false
        }
    }
}
