// A value class member called with a type-parameter-typed argument binds
// directly: the class is final and its `set(value: V, block)` is the only
// candidate, while the `@Deprecated(level = HIDDEN)` `set(value: Int, block)`
// overload is never a source-level candidate. Inside a generic helper the
// argument's static type is `T`, which cannot refute either overload by
// shape alone.

class Node {
    var text: String = ""
    var count: Int = 0
    val log = mutableListOf<String>()
}

value class Updater<T>(val node: Node) {
    @Deprecated("boxes", level = DeprecationLevel.HIDDEN)
    fun set(value: Int, block: T.(Int) -> Unit) {
        node.log.add("hidden")
    }

    fun <V> set(value: V, block: T.(V) -> Unit) {
        node.log.add("generic:$value")
        @Suppress("UNCHECKED_CAST")
        (node as T).block(value)
    }
}

inline fun <T> emit(node: Node, update: Updater<T>.() -> Unit) {
    Updater<T>(node).update()
}

fun <T> textNode(node: Node, value: T) {
    emit<Node>(node) { set(value) { text = it.toString() } }
}

fun <T : Any> countNode(node: Node, value: T) {
    emit<Node>(node) {
        set(value) { count = it.toString().length }
        set(7) { count += it }
    }
}

fun main() {
    val n = Node()
    textNode(n, "hello")
    println(n.text)
    countNode(n, 12345)
    println(n.count)
    println(n.log)
}
