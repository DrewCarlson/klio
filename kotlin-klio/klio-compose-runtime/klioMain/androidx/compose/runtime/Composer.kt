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

    /**
     * Whether the group just entered by [startGroup] should execute its body
     * this pass, given the hash of the call's arguments. False means skip: the
     * group was composed before, its args are unchanged, and it is not on an
     * invalidated path, so its slots and child groups are reused unchanged.
     */
    public fun shouldRunGroup(argsHash: Long): Boolean

    /** Push a CompositionLocal provider layer for the enclosed content. */
    public fun startProviders(values: Array<out ProvidedValue<*>>)

    /** Pop the most recent provider layer. */
    public fun endProviders()

    /** The nearest provided value for [local], or its default. */
    public fun consume(local: CompositionLocal<*>): Any?

    public companion object {
        /** Sentinel for an unwritten slot — distinct from any user value (incl. null). */
        public val Empty: Any = EmptySlot
    }
}

private object EmptySlot {
    override fun toString(): String = "Composer.Empty"
}

/** One positional group: an ordered slot list, keyed child groups, and the
 * recompose-scope bookkeeping (parent link, read set, composed flag). */
internal class GroupNode(@JvmField val key: Long, @JvmField val parent: GroupNode?) {
    @JvmField val slots: ArrayList<Any?> = ArrayList()
    @JvmField val children: HashMap<Long, GroupNode> = HashMap()
    @JvmField var slotCursor: Int = 0
    @JvmField val childOccurrences: HashMap<Long, Int> = HashMap()

    /** State objects read while this group last executed (its subscriptions). */
    @JvmField val reads: HashSet<Any> = HashSet()

    /** True once this group has executed at least once. */
    @JvmField var composed: Boolean = false

    /** Hash of the arguments this group last (re)composed with. */
    @JvmField var lastArgsHash: Long = 0L

    /** Reset the per-composition-pass cursors before (re)entering this group. */
    fun enterPass() {
        slotCursor = 0
        childOccurrences.clear()
    }
}

internal class KlioComposer : Composer {
    private val root = GroupNode(0L, null)
    private val stack = ArrayList<GroupNode>()

    /** The recomposer driving this composition; effects launch onto its scope. */
    @JvmField var recomposer: Recomposer? = null

    // Recomposition state.
    private val stateToGroups = HashMap<Any, HashSet<GroupNode>>()  // state -> subscribed groups
    private val invalidated = HashSet<GroupNode>()                  // groups awaiting recompose
    private var runSet: HashSet<GroupNode>? = null                  // null => run everything (initial pass)

    // CompositionLocal provider layers, outermost first.
    private val localsStack = ArrayList<HashMap<CompositionLocal<*>, Any?>>()

    // Effects: side effects queued during a pass (run after it), the live
    // DisposableEffect results (disposed on key change / composition dispose),
    // and generic cleanups (e.g. cancelling a remembered CoroutineScope).
    private val sideEffects = ArrayList<() -> Unit>()
    private val disposers = ArrayList<DisposableEffectResult>()
    private val cleanups = ArrayList<() -> Unit>()
    private val rememberObservers = ArrayList<RememberObserver>()

    init {
        stack.add(root)
    }

    private fun current(): GroupNode = stack[stack.size - 1]

    /** Begin the initial composition pass (every group executes). */
    fun beginInitialPass() {
        runSet = null
    }

    /**
     * Begin a recomposition pass: only invalidated groups and their ancestors
     * (the path that reaches them) execute; every other composed group skips.
     */
    fun beginRecomposePass() {
        val rs = HashSet<GroupNode>()
        for (g in invalidated) {
            var n: GroupNode? = g
            while (n != null && rs.add(n)) n = n.parent
        }
        invalidated.clear()
        runSet = rs
    }

    /** Reset the stack + root cursor for a pass (init/recompose already chosen). */
    fun beginCompose() {
        stack.clear()
        stack.add(root)
        root.enterPass()
        localsStack.clear()
    }

    fun endCompose() {
        // Group balance is the interpreter's responsibility (startGroup/endGroup
        // are emitted around every @Composable body); nothing to settle here.
    }

    /** True if a state write has invalidated at least one composed group. */
    val hasInvalidations: Boolean
        get() = invalidated.isNotEmpty()

    /** Record that the current group read [state] (called by the read observer). */
    fun subscribeRead(state: Any) {
        val g = current()
        if (g.reads.add(state)) {
            var set = stateToGroups[state]
            if (set == null) {
                set = HashSet()
                stateToGroups[state] = set
            }
            set.add(g)
        }
    }

    /** Mark groups subscribed to [state] for recomposition; true if any matched. */
    fun invalidate(state: Any): Boolean {
        val groups = stateToGroups[state] ?: return false
        if (groups.isEmpty()) return false
        for (g in groups) invalidated.add(g)
        return true
    }

    private fun clearReads(g: GroupNode) {
        for (s in g.reads) stateToGroups[s]?.remove(g)
        g.reads.clear()
    }

    override fun startGroup(key: Long) {
        val parent = current()
        val occ = parent.childOccurrences[key] ?: 0
        parent.childOccurrences[key] = occ + 1
        val cid = key * 1000003L + occ.toLong()
        var node = parent.children[cid]
        if (node == null) {
            node = GroupNode(key, parent)
            parent.children[cid] = node
        }
        node.enterPass()
        stack.add(node)
    }

    override fun shouldRunGroup(argsHash: Long): Boolean {
        val g = current()
        val rs = runSet
        // Run when fresh, when the whole tree runs (initial pass), when on the
        // invalidated path, or when the arguments changed since last pass.
        val should = !g.composed || rs == null || rs.contains(g) || g.lastArgsHash != argsHash
        if (should) {
            // The group is (re)running: drop its stale subscriptions; they
            // re-accumulate as the body re-reads state this pass.
            clearReads(g)
            g.composed = true
            g.lastArgsHash = argsHash
        }
        return should
    }

    override fun endGroup() {
        if (stack.size > 1) stack.removeAt(stack.size - 1)
    }

    override fun startProviders(values: Array<out ProvidedValue<*>>) {
        val layer = HashMap<CompositionLocal<*>, Any?>()
        for (pv in values) layer[pv.compositionLocal] = pv.value
        localsStack.add(layer)
    }

    override fun endProviders() {
        if (localsStack.isNotEmpty()) localsStack.removeAt(localsStack.size - 1)
    }

    override fun consume(local: CompositionLocal<*>): Any? {
        var i = localsStack.size - 1
        while (i >= 0) {
            val layer = localsStack[i]
            if (layer.containsKey(local)) return layer[local]
            i = i - 1
        }
        return local.defaultFactory()
    }

    // ----- effects -----

    fun recordSideEffect(effect: () -> Unit) {
        sideEffects.add(effect)
    }

    /** Run + clear the side effects queued during the pass just finished. */
    fun runSideEffects() {
        if (sideEffects.isEmpty()) return
        val pending = ArrayList(sideEffects)
        sideEffects.clear()
        for (e in pending) e()
    }

    fun addDisposer(result: DisposableEffectResult) {
        disposers.add(result)
    }

    fun removeDisposer(result: DisposableEffectResult) {
        disposers.remove(result)
    }

    /** Register a cleanup to run when the composition is disposed. */
    fun registerCleanup(cleanup: () -> Unit) {
        cleanups.add(cleanup)
    }

    /** Track a remembered RememberObserver (its onRemembered already ran). */
    fun registerRememberObserver(observer: RememberObserver) {
        rememberObservers.add(observer)
    }

    /** Dispose every live DisposableEffect + cleanup + RememberObserver, in reverse order. */
    fun disposeAll() {
        val live = ArrayList(disposers)
        disposers.clear()
        var i = live.size - 1
        while (i >= 0) {
            live[i].onDispose()
            i = i - 1
        }
        val cl = ArrayList(cleanups)
        cleanups.clear()
        var j = cl.size - 1
        while (j >= 0) {
            cl[j]()
            j = j - 1
        }
        val ro = ArrayList(rememberObservers)
        rememberObservers.clear()
        var k = ro.size - 1
        while (k >= 0) {
            ro[k].onForgotten()
            k = k - 1
        }
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
