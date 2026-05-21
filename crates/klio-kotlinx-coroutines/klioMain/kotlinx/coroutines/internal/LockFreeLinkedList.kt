// klio actual for the upstream `expect` lock-free intrusive list.
//
// Not actually lock-free: every mutation and traversal takes the
// monitor on the list's head node. This is correct (multiple
// `Dispatchers.Default` workers can call `addLast` / `remove` /
// `forEach` concurrently without losing entries or seeing a torn
// list) at the cost of coarse-grained exclusion. Upgrading to a
// real CAS-based lock-free node would let multiple workers progress
// in parallel on disjoint list operations, but the cancellation
// handler list (the primary upstream consumer) is short-lived
// per-coroutine, so contention is naturally low.
//
// The monitor is rooted at the head node so all nodes that belong
// to a single list serialize through the same lock — `addLast` /
// `remove` mutate two adjacent links and must be atomic with
// respect to a concurrent `forEach` that walks them. Each node
// caches a reference to its head so non-head mutators can find
// the right lock without an extra parameter.

package kotlinx.coroutines.internal

public actual open class LockFreeLinkedListNode actual constructor() {
    private var nextRef: LockFreeLinkedListNode = this
    private var prevRef: LockFreeLinkedListNode = this
    private var removed: Boolean = false
    private var forbidden: Int = 0

    // Head of the list this node belongs to. A free-standing node
    // (not yet linked) is its own head, which makes single-node
    // operations on a detached node lock its own monitor — fine
    // because no other worker can see it yet.
    internal var head: LockFreeLinkedListNode = this

    public actual val isRemoved: Boolean get() = kotlin.synchronized(head) { removed }
    public actual val nextNode: LockFreeLinkedListNode get() = kotlin.synchronized(head) { nextRef }
    public actual val prevNode: LockFreeLinkedListNode get() = kotlin.synchronized(head) { prevRef }

    public actual fun addLast(node: LockFreeLinkedListNode, permissionsBitmask: Int): Boolean =
        kotlin.synchronized(head) {
            if (forbidden and permissionsBitmask != 0) return@synchronized false
            val prev = this.prevRef
            node.nextRef = this
            node.prevRef = prev
            node.head = head
            prev.nextRef = node
            this.prevRef = node
            true
        }

    public actual fun addOneIfEmpty(node: LockFreeLinkedListNode): Boolean =
        kotlin.synchronized(head) {
            if (nextRef !== this) return@synchronized false
            // Inline of addLast(node, 0) under the same monitor so
            // the "empty" check + insert is one atomic step.
            val prev = this.prevRef
            node.nextRef = this
            node.prevRef = prev
            node.head = head
            prev.nextRef = node
            this.prevRef = node
            true
        }

    public actual open fun remove(): Boolean = kotlin.synchronized(head) {
        if (removed) return@synchronized false
        val p = prevRef
        val n = nextRef
        p.nextRef = n
        n.prevRef = p
        removed = true
        true
    }

    public actual fun close(forbiddenElementsBit: Int) {
        kotlin.synchronized(head) {
            forbidden = forbidden or forbiddenElementsBit
        }
    }

    internal fun headForEach(block: (LockFreeLinkedListNode) -> Unit) {
        // Snapshot the visit set under the lock, then invoke the
        // user block outside the lock so a callback that re-enters
        // the list (a handler that removes itself) doesn't
        // self-deadlock on the same monitor.
        val visit = kotlin.synchronized(head) {
            val acc = ArrayList<LockFreeLinkedListNode>()
            var cur = nextRef
            while (cur !== this) {
                if (!cur.removed) acc.add(cur)
                cur = cur.nextRef
            }
            acc
        }
        for (node in visit) block(node)
    }
}

public actual open class LockFreeLinkedListHead actual constructor() : LockFreeLinkedListNode() {
    public actual inline fun forEach(block: (LockFreeLinkedListNode) -> Unit) {
        headForEach(block)
    }

    public actual final override fun remove(): Nothing =
        throw UnsupportedOperationException("head cannot be removed")
}
