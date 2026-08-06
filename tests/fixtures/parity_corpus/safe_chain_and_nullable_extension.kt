class Leaf(val n: Int) { fun twice(): Int = n * 2 }
class Node(val leaf: Leaf?) { fun self(): Node = this }

fun through(node: Node?): Int = node?.self()?.leaf?.twice() ?: -1

fun stepwise(node: Node?): Int {
    val held = node?.self()
    val mid = node?.self()?.leaf
    return (held?.leaf?.twice() ?: 0) + (mid?.twice() ?: 0)
}

class Bag(val bytes: ByteArray?, val words: Array<String>?)

fun sameBytes(a: Bag, b: ByteArray?): Boolean = a.bytes.contentEquals(b)
fun sameWords(a: Bag, b: Array<String>?): Boolean = a.words.contentEquals(b)
fun render(a: Bag): String = a.words?.get(0).toString()

fun main() {
    val n = Node(Leaf(4))
    println(through(n))
    println(through(Node(null)))
    println(through(null))
    println(stepwise(n))
    val bag = Bag(byteArrayOf(1, 2), arrayOf("x", "y"))
    println(sameBytes(bag, byteArrayOf(1, 2)))
    println(sameBytes(bag, byteArrayOf(9)))
    println(sameBytes(Bag(null, null), null))
    println(sameWords(bag, arrayOf("x", "y")))
    println(render(bag))
    println(render(Bag(null, null)))
}
