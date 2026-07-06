// klio's Applier — the node-emission target a node-based Compose UI renders into.
//
// Upstream's Applier drives tree edits recorded into a changelist during the
// gap-buffer apply phase. klio composes synchronously (see Composer.kt): the
// KlioComposer applies node edits immediately, so this is the plain upstream
// Applier<N> contract (navigate with down/up, mutate with insert/remove/move)
// that a UI toolkit (Mosaic's MosaicNodeApplier, Compose-UI's LayoutNode applier)
// implements. Only the members a consumer actually binds against are kept; the
// internal OffsetApplier / ThrowingApplierStub (changelist-only helpers) are not
// needed by the synchronous engine.

package androidx.compose.runtime

import androidx.compose.runtime.internal.JvmDefaultWithCompatibility

/**
 * Applies the tree operations emitted during composition. Every node-emitting
 * [Composition] has an [Applier]; `ComposeNode { … }` drives it. Implement one to
 * build and maintain a tree of a novel node type.
 */
@JvmDefaultWithCompatibility
public interface Applier<N> {
    /** The node edits currently apply to; changes as [down]/[up] navigate. */
    public val current: N

    /** The composer is about to apply a batch of changes. */
    public fun onBeginChanges() {}

    /** The batch of changes started by [onBeginChanges] is complete. */
    public fun onEndChanges() {}

    /** Descend into [node] (a child of [current]); [node] becomes [current]. */
    public fun down(node: N)

    /** Ascend to the parent of [current]; the parent becomes [current]. */
    public fun up()

    /** Insert [instance] as a child of [current] at [index], before its children exist. */
    public fun insertTopDown(index: Int, instance: N)

    /** Insert [instance] as a child of [current] at [index], after its children exist. */
    public fun insertBottomUp(index: Int, instance: N)

    /** Remove [count] children of [current] starting at [index]. */
    public fun remove(index: Int, count: Int)

    /** Move [count] children of [current] from [from] to [to] ([to] is pre-move relative). */
    public fun move(from: Int, to: Int, count: Int)

    /** Return to the root and remove every node, readying it for a new composition. */
    public fun clear()

    /** Apply a property change to [current]. */
    public fun apply(block: N.(Any?) -> Unit, value: Any?) {
        current.block(value)
    }
}

/**
 * The common [Applier] base: a navigation stack over a mutable [root], with the
 * [MutableList.remove]/[MutableList.move] helpers a concrete applier uses to edit
 * a node's child list. A subclass supplies node-type-specific insert/remove/move
 * and [onClear].
 */
public abstract class AbstractApplier<T>(public val root: T) : Applier<T> {
    private val stack = ArrayList<T>()

    override var current: T = root
        protected set

    override fun down(node: T) {
        stack.add(current)
        current = node
    }

    override fun up() {
        check(stack.isNotEmpty()) { "empty stack" }
        current = stack.removeAt(stack.size - 1)
    }

    final override fun clear() {
        stack.clear()
        current = root
        onClear()
    }

    /** Clear the [root]'s children when [clear] is called. */
    protected abstract fun onClear()

    protected fun MutableList<T>.remove(index: Int, count: Int) {
        if (count == 1) {
            removeAt(index)
        } else {
            subList(index, index + count).clear()
        }
    }

    protected fun MutableList<T>.move(from: Int, to: Int, count: Int) {
        val dest = if (from > to) to else to - count
        if (count == 1) {
            if (from == to + 1 || from == to - 1) {
                val fromEl = get(from)
                val toEl = set(to, fromEl)
                set(from, toEl)
            } else {
                val fromEl = removeAt(from)
                add(dest, fromEl)
            }
        } else {
            val subView = subList(from, from + count)
            val subCopy = subView.toMutableList()
            subView.clear()
            addAll(dest, subCopy)
        }
    }
}
