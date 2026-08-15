// An object expression returned from a generic factory declares members whose
// parameter types name the factory's type parameter. Dispatch must read `Key`
// as a type variable, not as an unrelated class that happens to share the
// simple name (like kotlinx.coroutines' `CoroutineContext.Key`).

interface Key

fun <Key : Any> setOfKeys(): MutableSet<Key> = object : MutableSet<Key> {
    private val delegate = mutableMapOf<Key, Unit>()

    override fun add(element: Key): Boolean {
        val fresh = element !in delegate
        delegate[element] = Unit
        return fresh
    }

    override fun addAll(elements: Collection<Key>): Boolean =
        elements.fold(false) { modified, element -> add(element) || modified }

    override fun clear() = delegate.clear()
    override fun iterator(): MutableIterator<Key> = delegate.keys.iterator()
    override fun remove(element: Key): Boolean = delegate.remove(element) != null
    override fun removeAll(elements: Collection<Key>): Boolean {
        var changed = false
        for (e in elements) if (remove(e)) changed = true
        return changed
    }
    override fun retainAll(elements: Collection<Key>): Boolean {
        val drop = delegate.keys.filter { it !in elements }
        return removeAll(drop)
    }
    override val size: Int get() = delegate.size
    override fun contains(element: Key): Boolean = element in delegate
    override fun containsAll(elements: Collection<Key>): Boolean = elements.all { it in delegate }
    override fun isEmpty(): Boolean = delegate.isEmpty()
}

fun main() {
    val set = setOfKeys<String>()
    println(set.add("a"))
    println(set.add("a"))
    println(set.addAll(listOf("b", "c", "a")))
    println(set.size)
    println(set.remove("b"))
    println(set.contains("c"))
    println("done")
}
