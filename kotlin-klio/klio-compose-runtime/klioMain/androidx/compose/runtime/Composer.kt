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

    /** Cache the current group's @Composable return value, for reuse when the
     * group is skipped on a later pass. */
    public fun setGroupReturn(value: Any?)

    /** The current group's cached @Composable return value, or [Unit] if the
     * group has never recorded one. */
    public fun groupReturn(): Any?

    /** Push a CompositionLocal provider layer for the enclosed content. */
    public fun startProviders(values: Array<out ProvidedValue<*>>)

    /** Pop the most recent provider layer. */
    public fun endProviders()

    /** The nearest provided value for [local], or its default. */
    public fun consume(local: CompositionLocal<*>): Any?

    /**
     * A snapshot of all CompositionLocals in scope at this point, as the immutable
     * [CompositionLocalMap] the node engine stores on a LayoutNode (via
     * `ComposeUiNode.SetResolvedCompositionLocals`) so Modifier.Nodes can read
     * locals with `currentValueOf`.
     */
    public val currentCompositionLocalMap: CompositionLocalMap

    /** A stable hash of the current group's position in the composition tree (the
     * accumulated positional-key path from the root); backs
     * `currentCompositeKeyHashCode`, which `rememberSaveable` uses to key stored
     * state by call-site position. */
    public val compositeKeyHashCode: Long

    // ----- node emission (the Applier path) -----

    /** True while emitting a freshly-inserted node ([createNode]); false when a
     * prior pass's node is being reused ([useNode]). Drives `Updater` diffing. */
    public val inserting: Boolean

    /**
     * Whether the composer is currently SKIPPING content rather than
     * composing it. klio decides skipping per group before the body runs
     * (`shouldRunGroup`), so inside a running body this is always false.
     */
    public val skipping: Boolean

    /** The node-tree applier this composition renders into, or null for a
     * logic-only (side-effect) composition that emits no nodes. */
    public val applier: Applier<*>?

    /** Begin emitting a node at the current position (opens the node's group). */
    public fun startNode()

    /** Begin emitting a reusable node at the current position. */
    public fun startReusableNode()

    /** Create the node for the open [startNode] via [factory] — first pass only. */
    public fun createNode(factory: () -> Any?)

    /** Reuse the node stored for the open [startNode] on a later pass. */
    public fun useNode()

    /** Finish the node opened by [startNode] (reconciles its children, closes the group). */
    public fun endNode()

    /** Open a replaceable positional group (node-emit skippable update + conditional content). */
    public fun startReplaceableGroup(key: Int)

    /** Close the group opened by [startReplaceableGroup]. */
    public fun endReplaceableGroup()

    /** Open a replaceable positional group (current upstream name for
     * [startReplaceableGroup]). */
    public fun startReplaceGroup(key: Int)

    /** Close the group opened by [startReplaceGroup]. */
    public fun endReplaceGroup()

    public companion object {
        /** Sentinel for an unwritten slot — distinct from any user value (incl. null). */
        public val Empty: Any = EmptySlot
    }
}

private object EmptySlot {
    override fun toString(): String = "Composer.Empty"
}

/** Sentinel for a group that has not yet emitted a node — distinct from a node
 * value of null, which a factory may legitimately produce. */
private object NoNode

/** One positional group: an ordered slot list, keyed child groups, and the
 * recompose-scope bookkeeping (parent link, read set, composed flag). */
internal class GroupNode(@JvmField val key: Long, @JvmField val parent: GroupNode?) {
    @JvmField val slots: ArrayList<Any?> = ArrayList()
    @JvmField val children: HashMap<Long, GroupNode> = HashMap()
    @JvmField var slotCursor: Int = 0
    @JvmField val childOccurrences: HashMap<Long, Int> = HashMap()

    // ----- node emission -----
    /** The emitted node this group owns (a node-group), or [NoNode] if none. */
    @JvmField var node: Any? = NoNode
    /** The applier child order under this group's node, from the last pass. */
    @JvmField var childNodeOrder: ArrayList<GroupNode>? = null
    /** Node-groups this group put into its enclosing applier node last pass —
     * re-listed when the group is skipped so its nodes are retained. */
    @JvmField var contributedNodes: ArrayList<GroupNode>? = null
    /** Pass id in which this group was last entered by [KlioComposer.startGroup]. */
    @JvmField var visitedPass: Int = -1
    /** Pass id in which this group last ran its body (not skipped). */
    @JvmField var ranPass: Int = -1

    /** State objects read while this group last executed (its subscriptions). */
    @JvmField val reads: HashSet<Any> = HashSet()

    /** True once this group has executed at least once. */
    @JvmField var composed: Boolean = false

    /** Hash of the arguments this group last (re)composed with. */
    @JvmField var lastArgsHash: Long = 0L

    /** The @Composable's return value from its last execution, reused verbatim
     * when this group is skipped. [Composer.Empty] until first recorded. */
    @JvmField var returnValue: Any? = Composer.Empty

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

    // Node emission. `applierNode` is the composition's applier (null for a
    // logic-only composition). `emitStack` tracks, per open applier node, the
    // ordered node-groups emitted under it this pass; on close the applier's
    // child list is reconciled (insert/remove/move) to match. `rootChildOrder`
    // is the applier root's child order across passes.
    @JvmField var applierNode: Applier<Any?>? = null
    private val emitStack = ArrayList<EmitContext>()
    private var rootChildOrder = ArrayList<GroupNode>()
    private val insertingStack = ArrayList<Boolean>()
    private val startLenStack = ArrayList<Int>()
    private var passId: Int = 0

    /** Fixed group key for a node's positional group; per-occurrence
     * disambiguation gives each `ComposeNode` call in a body its own group. */
    private val nodeGroupKey = 0x4b4c494f4e4f4445L

    /** One open applier node: the group that owns it (null for the root) and the
     * ordered node-groups emitted directly under it during the current pass. */
    private class EmitContext(@JvmField val ownerGroup: GroupNode?) {
        @JvmField val newOrder = ArrayList<GroupNode>()
    }

    // CompositionLocal provider layers, outermost first.
    private val localsStack = ArrayList<HashMap<CompositionLocal<*>, Any?>>()

    /** Locals inherited from the parent composition (a subcomposition created
     * through `rememberCompositionContext`): the parent's merged provider
     * snapshot, consulted after this composer's own provider layers. */
    internal var baseLocals: HashMap<CompositionLocal<*>, Any?>? = null

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
        passId += 1
        emitStack.clear()
        insertingStack.clear()
        startLenStack.clear()
        if (applierNode != null) emitStack.add(EmitContext(null))
    }

    fun endCompose() {
        // Reconcile the applier root's children to this pass's emission order.
        // Group balance itself is the interpreter's responsibility (startGroup /
        // endGroup bracket every @Composable body).
        val applier = applierNode
        if (applier != null && emitStack.isNotEmpty()) {
            reconcileChildren(applier, rootChildOrder, emitStack[0].newOrder)
            rootChildOrder = emitStack[0].newOrder
        }
        emitStack.clear()
        insertingStack.clear()
    }

    /** True if a state write has invalidated at least one composed group. */
    val hasInvalidations: Boolean
        get() = invalidated.isNotEmpty()

    /**
     * A handle on the group being composed, which can invalidate itself later.
     * This is what `currentRecomposeScope` hands out: upstream keys a
     * RecomposeScope to a slot-table group, and klio's positional [GroupNode] IS
     * that group, so invalidating the scope is simply marking that node for the
     * next pass — the same set [invalidate] marks on a state write.
     */
    fun currentRecomposeScope(): RecomposeScope = GroupRecomposeScope(this, current())

    /** Mark [g] for recomposition (see [currentRecomposeScope]). */
    internal fun invalidateGroup(g: GroupNode) {
        invalidated.add(g)
    }

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
        // Node bookkeeping: mark visited, assume it runs (shouldRunGroup clears
        // ranPass on a skip), and snapshot the enclosing emit order length so
        // endGroup can record the node-groups this group contributes.
        node.visitedPass = passId
        node.ranPass = passId
        startLenStack.add(if (emitStack.isEmpty()) 0 else emitStack[emitStack.size - 1].newOrder.size)
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
        } else {
            // Skipped: its body will not run, so it emits nothing this pass. Its
            // subtree's nodes stay in the tree — re-list the node-groups it
            // contributed so the enclosing reconcile keeps them, and mark it not
            // run so endGroup leaves its children untouched.
            g.ranPass = -1
            val contributed = g.contributedNodes
            if (contributed != null && emitStack.isNotEmpty()) {
                emitStack[emitStack.size - 1].newOrder.addAll(contributed)
            }
        }
        return should
    }

    override fun setGroupReturn(value: Any?) {
        current().returnValue = value
    }

    override fun groupReturn(): Any? {
        val v = current().returnValue
        return if (v === Composer.Empty) Unit else v
    }

    override fun endGroup() {
        val g = current()
        // Record the node-groups this group contributed to its enclosing applier
        // node this pass (the emit-order slice since startGroup) — replayed if the
        // group is skipped next time.
        val startLen = if (startLenStack.isEmpty()) 0 else startLenStack.removeAt(startLenStack.size - 1)
        if (emitStack.isNotEmpty()) {
            val enclosing = emitStack[emitStack.size - 1].newOrder
            val contributed = ArrayList<GroupNode>()
            var i = startLen
            while (i < enclosing.size) {
                contributed.add(enclosing[i]); i += 1
            }
            g.contributedNodes = contributed
        }
        // A group that ran its body may have dropped conditional children; forget
        // any child group not entered this pass so its state is released and a
        // later re-entry starts fresh. A skipped group's children are untouched.
        if (g.ranPass == passId && g.children.isNotEmpty()) {
            val it = g.children.entries.iterator()
            while (it.hasNext()) {
                val child = it.next().value
                if (child.visitedPass != passId) {
                    forgetGroupState(child)
                    it.remove()
                }
            }
        }
        if (stack.size > 1) stack.removeAt(stack.size - 1)
    }

    // ----- node emission -----

    override val applier: Applier<*>?
        get() = applierNode

    override val skipping: Boolean
        get() = false

    override val inserting: Boolean
        get() = insertingStack.isNotEmpty() && insertingStack[insertingStack.size - 1]

    override fun startNode() {
        startGroup(nodeGroupKey)
        insertingStack.add(current().node === NoNode)
    }

    override fun startReusableNode() {
        startNode()
    }

    override fun createNode(factory: () -> Any?) {
        val g = current()
        val node = factory()
        g.node = node
        emitStack[emitStack.size - 1].newOrder.add(g)
        applierNode!!.down(node)
        emitStack.add(EmitContext(g))
    }

    override fun useNode() {
        val g = current()
        emitStack[emitStack.size - 1].newOrder.add(g)
        applierNode!!.down(g.node)
        emitStack.add(EmitContext(g))
    }

    override fun endNode() {
        val ctx = emitStack.removeAt(emitStack.size - 1)
        val g = ctx.ownerGroup!!
        val shadow = g.childNodeOrder ?: ArrayList()
        reconcileChildren(applierNode!!, shadow, ctx.newOrder)
        g.childNodeOrder = ctx.newOrder
        applierNode!!.up()
        if (insertingStack.isNotEmpty()) insertingStack.removeAt(insertingStack.size - 1)
        endGroup()
    }

    override fun startReplaceableGroup(key: Int) {
        startGroup(key.toLong())
    }

    override fun endReplaceableGroup() {
        endGroup()
    }

    override fun startReplaceGroup(key: Int) {
        startGroup(key.toLong())
    }

    override fun endReplaceGroup() {
        endGroup()
    }

    /**
     * Bring [applier]'s children of the current node from [shadow] (their order
     * last pass) to [newOrder] (this pass's emission order): remove vanished
     * node-groups, then insert new ones and move existing ones into position.
     * [shadow] is mutated in lockstep with the applier so indices stay valid.
     */
    private fun reconcileChildren(
        applier: Applier<Any?>,
        shadow: MutableList<GroupNode>,
        newOrder: List<GroupNode>,
    ) {
        var i = shadow.size - 1
        while (i >= 0) {
            val g = shadow[i]
            if (!newOrder.contains(g)) {
                applier.remove(i, 1)
                shadow.removeAt(i)
                forgetGroupState(g)
            }
            i -= 1
        }
        var t = 0
        while (t < newOrder.size) {
            val g = newOrder[t]
            val cur = shadow.indexOf(g)
            if (cur == -1) {
                // An applier implements exactly one of insertTopDown / insertBottomUp
                // (the other is a no-op). The child's own subtree is already built
                // by the time it is inserted here, so call both and let the applier
                // use whichever it implements.
                applier.insertTopDown(t, g.node)
                applier.insertBottomUp(t, g.node)
                shadow.add(t, g)
            } else if (cur != t) {
                val toArg = if (cur > t) t else t + 1
                applier.move(cur, toArg, 1)
                val el = shadow.removeAt(cur)
                shadow.add(t, el)
            }
            t += 1
        }
    }

    /** Release a removed subtree's state so a later re-entry starts fresh. */
    private fun forgetGroupState(g: GroupNode) {
        clearReads(g)
        for (c in g.children.values) forgetGroupState(c)
        g.children.clear()
    }

    override fun startProviders(values: Array<out ProvidedValue<*>>) {
        val layer = HashMap<CompositionLocal<*>, Any?>()
        for (pv in values) {
            // `providesDefault` binds only when no enclosing provider already
            // supplies the local; the outer binding wins otherwise.
            if (pv.isDefault && isLocalProvided(pv.compositionLocal)) continue
            layer[pv.compositionLocal] = pv.value
        }
        localsStack.add(layer)
    }

    private fun isLocalProvided(local: CompositionLocal<*>): Boolean {
        var i = localsStack.size - 1
        while (i >= 0) {
            if (localsStack[i].containsKey(local)) return true
            i = i - 1
        }
        val base = baseLocals
        return base != null && base.containsKey(local)
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
        val base = baseLocals
        if (base != null && base.containsKey(local)) return base[local]
        return local.defaultFactory()
    }

    override val currentCompositionLocalMap: CompositionLocalMap
        get() {
            val base = baseLocals
            if (localsStack.isEmpty() && base == null) return CompositionLocalMap.Empty
            val merged = HashMap<CompositionLocal<*>, Any?>()
            if (base != null) merged.putAll(base)
            for (layer in localsStack) merged.putAll(layer) // outer→inner; inner wins
            return KlioCompositionLocalMap(merged)
        }

    override val compositeKeyHashCode: Long
        get() {
            var hash = 0L
            var g: GroupNode? = if (stack.isEmpty()) root else current()
            while (g != null) {
                hash = hash * 31L + g.key
                g = g.parent
            }
            return hash
        }

    // ----- effects -----

    /** A subcomposition context tied to this composer's recomposer, so a child
     * composition created from it recomposes under the same recomposer. */
    fun buildContext(): CompositionContext {
        val rec = recomposer ?: error("rememberCompositionContext requires a recomposer")
        val merged = HashMap<CompositionLocal<*>, Any?>()
        baseLocals?.let { merged.putAll(it) }
        for (layer in localsStack) merged.putAll(layer)
        return KlioCompositionContext(rec, merged)
    }

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

    /** Forget everything composed (slots, invalidations, child order) so the
     * composer can host fresh content in the same applier tree. Runs the
     * disposers first, exactly like [disposeAll]. */
    fun resetForReuse() {
        disposeAll()
        root.children.clear()
        rootChildOrder = ArrayList()
        invalidated.clear()
        runSet = null
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
