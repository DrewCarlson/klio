// klio actual for the upstream `expect` lock-free intrusive list.
// klio runs one cooperative driver per `runBlocking`, so a plain
// intrusive doubly-linked list suffices; `addLast`'s permission
// bitmask and `close` are honoured so cancelling-vs-completion
// handler admission matches upstream ordering. Not a concurrent
// structure — there is never a concurrent observer in klio's model.

package kotlinx.coroutines.internal

public actual open class LockFreeLinkedListNode actual constructor() {
    private var nextRef: LockFreeLinkedListNode = this
    private var prevRef: LockFreeLinkedListNode = this
    private var removed: Boolean = false
    private var forbidden: Int = 0

    public actual val isRemoved: Boolean get() = removed
    public actual val nextNode: LockFreeLinkedListNode get() = nextRef
    public actual val prevNode: LockFreeLinkedListNode get() = prevRef

    public actual fun addLast(node: LockFreeLinkedListNode, permissionsBitmask: Int): Boolean {
        if (forbidden and permissionsBitmask != 0) return false
        val prev = this.prevRef
        node.nextRef = this
        node.prevRef = prev
        prev.nextRef = node
        this.prevRef = node
        return true
    }

    public actual fun addOneIfEmpty(node: LockFreeLinkedListNode): Boolean {
        if (nextRef !== this) return false
        return addLast(node, 0)
    }

    public actual open fun remove(): Boolean {
        if (removed) return false
        val p = prevRef
        val n = nextRef
        p.nextRef = n
        n.prevRef = p
        removed = true
        return true
    }

    public actual fun close(forbiddenElementsBit: Int) {
        forbidden = forbidden or forbiddenElementsBit
    }

    internal fun headForEach(block: (LockFreeLinkedListNode) -> Unit) {
        var cur = nextRef
        while (cur !== this) {
            val next = cur.nextRef
            if (!cur.removed) block(cur)
            cur = next
        }
    }
}

public actual open class LockFreeLinkedListHead actual constructor() : LockFreeLinkedListNode() {
    public actual inline fun forEach(block: (LockFreeLinkedListNode) -> Unit) {
        headForEach(block)
    }

    public actual final override fun remove(): Nothing =
        throw UnsupportedOperationException("head cannot be removed")
}
