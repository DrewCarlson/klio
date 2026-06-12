// klio actual for the upstream `expect` lock-free intrusive list.
//
// Verbatim Sundell-Tsigas algorithm structure adapted from
// `upstream/kotlinx-coroutines-core/concurrent/src/internal/LockFreeLinkedList.kt`:
// every link is an `atomic` reference, removed nodes are marked
// with the `Removed` sentinel on `_next`, and `correctPrev` runs
// the helping protocol when an observer encounters a half-completed
// remove. klio's atomicfu CAS is observed atomically under
// contention (the host binding compares and swaps under one
// exclusive borrow of the receiver's cell; see
// `src/kotlinx_atomicfu`), so the algorithm is sound across real
// `Dispatchers.Default` worker threads.

package kotlinx.coroutines.internal

import kotlinx.atomicfu.atomic
import kotlinx.atomicfu.loop

private typealias Node = LockFreeLinkedListNode

@Suppress("LeakingThis")
public actual open class LockFreeLinkedListNode actual constructor() {
    private val _next = atomic<Any>(this) // Node | Removed
    private val _prev = atomic(this) // Node to the left (cannot be marked as removed)
    private val _removedRef = atomic<Removed?>(null) // lazily cached removed ref to this

    private fun removed(): Removed {
        val cached = _removedRef.value
        if (cached != null) return cached
        val r = Removed(this)
        _removedRef.lazySet(r)
        return r
    }

    public actual open val isRemoved: Boolean get() = _next.value is Removed

    public actual val nextNode: Node get() {
        val n = _next.value
        return if (n is Removed) n.ref else n as Node
    }

    public actual val prevNode: Node
        get() = correctPrev() ?: findPrevNonRemoved(_prev.value)

    private tailrec fun findPrevNonRemoved(current: Node): Node {
        if (!current.isRemoved) return current
        return findPrevNonRemoved(current._prev.value)
    }

    public actual fun addOneIfEmpty(node: Node): Boolean {
        node._prev.lazySet(this)
        node._next.lazySet(this)
        while (true) {
            val next = _next.value
            if (next !== this) return false
            if (_next.compareAndSet(this, node)) {
                node.finishAdd(this)
                return true
            }
        }
    }

    public actual fun addLast(node: Node, permissionsBitmask: Int): Boolean {
        while (true) {
            val currentPrev = prevNode
            if (currentPrev is ListClosed) {
                return currentPrev.forbiddenElementsBitmask and permissionsBitmask == 0 &&
                    currentPrev.addLast(node, permissionsBitmask)
            }
            if (currentPrev.addNext(node, this)) return true
        }
    }

    public actual fun close(forbiddenElementsBit: Int) {
        addLast(ListClosed(forbiddenElementsBit), forbiddenElementsBit)
    }

    internal fun addNext(node: Node, next: Node): Boolean {
        node._prev.lazySet(this)
        node._next.lazySet(next)
        if (!_next.compareAndSet(next, node)) return false
        node.finishAdd(next)
        return true
    }

    public actual open fun remove(): Boolean = removeOrNext() == null

    internal fun removeOrNext(): Node? {
        while (true) {
            val next = _next.value
            if (next is Removed) return next.ref
            if (next === this) return next as Node
            val r = (next as Node).removed()
            if (_next.compareAndSet(next, r)) {
                next.correctPrev()
                return null
            }
        }
    }

    private fun finishAdd(next: Node) {
        next._prev.loop { nextPrev ->
            if (_next.value !== next) return
            if (next._prev.compareAndSet(nextPrev, this)) {
                if (isRemoved) next.correctPrev()
                return
            }
        }
    }

    private tailrec fun correctPrev(): Node? {
        val oldPrev = _prev.value
        var prev: Node = oldPrev
        var last: Node? = null
        while (true) {
            val prevNext: Any = prev._next.value
            when {
                prevNext === this -> {
                    if (oldPrev === prev) return prev
                    if (!_prev.compareAndSet(oldPrev, prev)) return correctPrev()
                    return prev
                }
                isRemoved -> return null
                prevNext is Removed -> {
                    val lastNode = last
                    if (lastNode !== null) {
                        if (!lastNode._next.compareAndSet(prev, prevNext.ref)) return correctPrev()
                        prev = lastNode
                        last = null
                    } else {
                        prev = prev._prev.value
                    }
                }
                else -> {
                    last = prev
                    prev = prevNext as Node
                }
            }
        }
    }
}

private class Removed(val ref: Node)

public actual open class LockFreeLinkedListHead actual constructor() : LockFreeLinkedListNode() {
    public actual inline fun forEach(block: (Node) -> Unit) {
        var cur: Node = nextNode
        while (cur !== this) {
            block(cur)
            cur = cur.nextNode
        }
    }

    public actual final override fun remove(): Nothing =
        throw UnsupportedOperationException("head cannot be removed")

    override val isRemoved: Boolean get() = false
}

private class ListClosed(val forbiddenElementsBitmask: Int) : LockFreeLinkedListNode()
