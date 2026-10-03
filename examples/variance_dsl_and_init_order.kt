// Declaration-site variance, type alias projections, `+=` on a `val`,
// property initialization order and a `@DslMarker` builder: the forms
// kotlinc accepts, each next to the rule it keeps.

// `out T` is produced only; `@UnsafeVariance` lets `contains` take a T.
class Stack<out T>(private val items: List<T>) {
    fun top(): T = items.last()
    fun contains(item: @UnsafeVariance T): Boolean = item in items
    fun <R> map(f: (T) -> R): Stack<R> = Stack(items.map(f))
}

// `in T` is consumed only.
class Printer<in T>(private val label: String) {
    fun print(value: T) = println("$label: $value")
}

typealias Bucket<K> = MutableList<K>

// A projected alias argument keeps its projection: `Bucket<out Number>`
// is `MutableList<out Number>`.
fun total(bucket: Bucket<out Number>): Double = bucket.sumOf { it.toDouble() }
fun fill(bucket: Bucket<in Int>) { bucket.add(7) }

// Only `plusAssign`, so `+=` on a `val` is not ambiguous.
class Tally(var count: Int) {
    operator fun plusAssign(n: Int) { count += n }
}

// Properties initialize in order; a lambda or function may read a later one.
class Config {
    val base = 10
    val doubled = base * 2
    val later = { last }
    val viaFun get() = describe()
    fun describe() = "base=$base last=$last"
    val last = doubled + 1
}

@DslMarker
annotation class HtmlMarker

@HtmlMarker
abstract class Tag(val name: String) {
    val children = mutableListOf<Tag>()
    fun render(): String = "<$name>" + children.joinToString("") { it.render() } + "</$name>"
}

class Html : Tag("html") {
    fun body(init: Body.() -> Unit) { children += Body().apply(init) }
}

class Body : Tag("body") {
    fun p(init: P.() -> Unit) { children += P().apply(init) }
}

class P : Tag("p")

fun html(init: Html.() -> Unit): Html = Html().apply(init)

fun main() {
    val stack: Stack<Number> = Stack(listOf(1, 2, 3))
    println("top=${stack.top()} has2=${stack.contains(2)} mapped=${stack.map { it.toInt() * 10 }.top()}")

    val anyPrinter: Printer<Any> = Printer("any")
    val intPrinter: Printer<Int> = anyPrinter
    intPrinter.print(42)

    val ints: MutableList<Int> = mutableListOf(1, 2)
    println("total=${total(ints)}")
    val anys = mutableListOf<Any>("start")
    fill(anys)
    println("filled=$anys")

    val tally = Tally(1)
    tally += 4
    println("tally=${tally.count}")

    val config = Config()
    println("doubled=${config.doubled} later=${config.later()} ${config.viaFun}")

    val page = html {
        body {
            p { }
            // An outer DSL receiver is reached by naming it.
            this@html.body { }
        }
    }
    println(page.render())
}
