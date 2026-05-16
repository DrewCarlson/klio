// Interface delegation, custom property delegates, generic variance,
// enum with abstract members, inner/nested classes, companion
// factories, operator invoke, infix, and lazy.

import kotlin.reflect.KProperty

interface Repository<out T> {
    fun all(): List<T>
    fun count(): Int = all().size
}

class ListRepository<T>(private val items: List<T>) : Repository<T> {
    override fun all(): List<T> = items
}

// Class delegation: Logged forwards Repository<T> to a delegate but
// overrides count() to record access.
class Logged<T>(private val inner: Repository<T>) : Repository<T> by inner {
    var reads = 0
        private set
    override fun count(): Int {
        reads++
        return inner.count()
    }
}

// Custom property delegate (operator getValue/setValue).
class Clamped(private var v: Int, private val lo: Int, private val hi: Int) {
    operator fun getValue(thisRef: Any?, prop: KProperty<*>): Int = v
    operator fun setValue(thisRef: Any?, prop: KProperty<*>, value: Int) {
        v = value.coerceIn(lo, hi)
    }
}

class Knob {
    var level: Int by Clamped(5, 0, 10)
}

enum class Op(val symbol: Char) {
    ADD('+') { override fun apply(a: Int, b: Int) = a + b },
    MUL('*') { override fun apply(a: Int, b: Int) = a * b },
    MAX('^') { override fun apply(a: Int, b: Int) = if (a > b) a else b };
    abstract fun apply(a: Int, b: Int): Int
}

class Matrix private constructor(private val rows: List<List<Int>>) {
    operator fun get(r: Int, c: Int): Int = rows[r][c]
    operator fun invoke(): Int = rows.sumOf { row -> row.sum() }

    inner class RowView(private val r: Int) {
        fun sum(): Int = rows[r].sum()
        operator fun get(c: Int): Int = rows[r][c]
    }
    fun row(r: Int) = RowView(r)

    companion object {
        fun of(vararg rows: List<Int>): Matrix = Matrix(rows.toList())
    }
}

infix fun Int.pow(e: Int): Int {
    var r = 1
    repeat(e) { r *= this }
    return r
}

class Cache {
    val expensive: String by lazy {
        buildString {
            append("computed:")
            (1..3).forEach { append(it) }
        }
    }
}

fun main() {
    val repo = Logged(ListRepository(listOf("a", "b", "c", "d")))
    println("all=${repo.all()} count=${repo.count()} count=${repo.count()} reads=${repo.reads}")

    val k = Knob()
    k.level = 99
    println("clamped=${k.level}")
    k.level = -4
    println("clamped=${k.level}")

    for (op in Op.entries) {
        println("${op.symbol} -> ${op.apply(6, 4)}")
    }

    val m = Matrix.of(listOf(1, 2, 3), listOf(4, 5, 6))
    println("m[1,2]=${m[1, 2]} total=${m()} row0sum=${m.row(0).sum()} row1[0]=${m.row(1)[0]}")

    println("2^10=${2 pow 10}")

    val c = Cache()
    println(c.expensive)
    println(c.expensive)

    // Variance: a Repository<String> is usable where Repository<Any>
    // is expected (declaration-site `out`).
    val anyRepo: Repository<Any> = ListRepository(listOf("x", "y"))
    println("anyRepo.count=${anyRepo.count()}")

    // Generic fn with reified-free upper bound + chained scope fns.
    fun <T : Comparable<T>> List<T>.medianish(): T =
        sorted().let { it[it.size / 2] }
    println(listOf(9, 1, 7, 3, 5).medianish())
    println(listOf("pear", "apple", "fig").medianish())
}
