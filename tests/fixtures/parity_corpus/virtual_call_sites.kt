// Virtual and interface calls from one call site over receivers of one,
// two and many classes: overrides, an implementation inherited from a
// superclass, bodies that only read a field, full bodies, recursion
// through a virtual call, interface calls whose receiver is sometimes
// a String rather than an instance, and calls the runtime implements for
// collection and scalar receivers mixed with user classes at one site.

abstract class Shape(val name: String) {
    abstract fun area(): Int
    open val sides: Int get() = 0
    open fun describe(): String = "$name with $sides sides, area ${area()}"
}

class Square(val side: Int) : Shape("square") {
    override fun area() = side * side
    override val sides get() = 4
}

class Rect(val w: Int, val h: Int) : Shape("rect") {
    override fun area() = w * h
    override val sides get() = 4
}

open class Tri(val base: Int, val height: Int) : Shape("tri") {
    override fun area() = base * height / 2
    override val sides get() = 3
}

class RightTri(base: Int, height: Int) : Tri(base, height)

class Circle(val r: Int) : Shape("circle") {
    override fun area() = 3 * r * r
    override fun describe() = "round $name, area ${area()}"
}

interface Node {
    fun sum(): Int
}

class Leaf(val v: Int) : Node {
    override fun sum() = v
}

class Pair2(val l: Node, val r: Node) : Node {
    override fun sum() = l.sum() + r.sum()
}

class Letters(private val s: String) : CharSequence {
    override val length: Int get() = s.length
    override fun get(index: Int): Char = s[index].uppercaseChar()
    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence = Letters(s.substring(startIndex, endIndex))
    override fun toString(): String = s.uppercase()
}

fun areaOf(s: Shape): Int = s.area()

fun sidesOf(s: Shape): Int = s.sides

fun lengthOf(cs: CharSequence): Int = cs.length

fun firstOf(cs: CharSequence): Char = cs[0]

class Evens(private val n: Int) : AbstractList<Int>() {
    override val size: Int get() = n
    override fun get(index: Int): Int = index * 2
}

fun sizeOf(c: Collection<Int>): Int = c.size

fun at(l: List<Int>, i: Int): Int = l[i]

fun textOf(x: Any): String = x.toString()

fun hashOf(x: Any): Int = x.hashCode()

fun tree(depth: Int, start: Int): Node =
    if (depth == 0) Leaf(start) else Pair2(tree(depth - 1, start), tree(depth - 1, start + (1 shl (depth - 1))))

fun main() {
    val one = List(5) { Square(it + 1) }
    println("one class: " + one.map { areaOf(it) })
    val two = List(8) { if (it % 2 == 0) Square(it) else Rect(it, 2) }
    println("two classes: " + two.map { areaOf(it) } + " " + two.map { sidesOf(it) })
    val many = listOf(Square(3), Rect(2, 5), Tri(4, 3), RightTri(6, 2), Circle(2), Square(1), Circle(1), Tri(2, 2))
    println("many classes: " + many.map { areaOf(it) } + " " + many.map { sidesOf(it) })
    for (s in many) println(s.describe())
    var total = 0
    for (round in 0 until 3) for (s in many) total += areaOf(s) + sidesOf(s)
    println("total $total")
    println("tree sums: " + (0..6).map { tree(it, 1).sum() })
    val texts: List<CharSequence> = listOf("klio", Letters("tail"), StringBuilder("call"), Letters("site"), "x")
    println("lengths: " + texts.map { lengthOf(it) })
    println("firsts: " + texts.map { firstOf(it) })
    println("strings: " + texts.map { it.toString() })
    val lists: List<List<Int>> = listOf(listOf(1, 2, 3), mutableListOf(4, 5), Evens(4), ArrayDeque(listOf(7, 8, 9)), listOf(10))
    var sum = 0
    for (round in 0 until 3) for (l in lists) sum += at(l, 0) + at(l, l.size - 1) + sizeOf(l)
    println("list sites: $sum " + lists.map { sizeOf(it) } + " " + lists.map { at(it, it.size / 2) })
    val sets: List<Collection<Int>> = listOf(setOf(1, 2), hashSetOf(3), Evens(3), mutableListOf(1, 1, 1, 1))
    println("collections: " + sets.map { sizeOf(it) })
    val anys: List<Any> = listOf(1, "two", 3L, 4.5, 'c', true, Evens(2), listOf(1))
    println("texts: " + anys.map { textOf(it) })
    println("hashes: " + anys.take(6).map { hashOf(it) })
}
