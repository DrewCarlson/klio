import kotlin.jvm.JvmInline

// Value classes over numbers sent through every place a value moves:
// generic calls and results, Any and nullable parameters, a vararg, if,
// when, try and ?: results, lambdas and inline lambdas, properties and
// fields, data classes and destructuring, collections, maps and sets,
// interfaces, smart casts, casts, loops, init blocks, companion values,
// arrays, callable references, sequences, equality and hashing.

@JvmInline
value class Meters(val v: Double) : Comparable<Meters> {
    operator fun plus(o: Meters) = Meters(v + o.v)
    operator fun times(k: Int) = Meters(v * k)
    override fun compareTo(other: Meters) = v.compareTo(other.v)
    override fun toString() = "${v}m"
    val half: Meters get() = Meters(v / 2)
    fun describe(): String = "Meters($v)"
}

@JvmInline
value class Id(val raw: Int) {
    init {
        require(raw >= 0) { "negative id $raw" }
    }

    companion object {
        val ZERO = Id(0)
    }
}

@JvmInline
value class Packed(val bits: Long) {
    constructor(x: Int, y: Int) : this((x.toLong() shl 32) or (y.toLong() and 0xffffffffL))
    val x: Int get() = (bits shr 32).toInt()
    val y: Int get() = bits.toInt()
}

interface Shape {
    fun area(): Double
}

@JvmInline
value class Square(val side: Double) : Shape {
    override fun area() = side * side
}

data class Box(val w: Meters, val id: Id?, val tags: List<Meters>)

class Holder(var m: Meters, var n: Meters?) {
    var p: Packed = Packed(1, 2)
}

fun <T> id(x: T): T = x
fun <T> first(xs: List<T>): T = xs[0]
fun takeAny(x: Any): String = x.toString() + ":" + (x is Meters) + ":" + x.hashCode()
fun takeNullable(x: Meters?): String = x?.toString() ?: "none"
fun total(vararg ms: Any): Double = ms.sumOf { (it as Meters).v }
fun pick(flag: Boolean, a: Meters, b: Meters): Meters = if (flag) a else b
fun maybe(flag: Boolean): Meters? = if (flag) Meters(1.0) else null
fun viaWhen(n: Int): Any = when (n) {
    0 -> Meters(0.5)
    1 -> Id(1)
    else -> "other"
}
fun elvis(m: Meters?): Meters = m ?: Meters(-1.0)
fun tryIt(fail: Boolean): Meters = try {
    if (fail) throw IllegalStateException("x")
    Meters(2.0)
} catch (e: IllegalStateException) {
    Meters(3.0)
}
fun lambdaApply(f: (Meters) -> Meters, m: Meters) = f(m)
inline fun inlineApply(m: Meters, f: (Meters) -> Meters) = f(m)

fun main() {
    val a = Meters(1.5)
    val b = Meters(2.0)
    println(a + b)
    println("sum ${a + b} times ${a * 3} half ${b.half} ${a.describe()}")
    println("${a == b} ${a == Meters(1.5)} ${a.compareTo(b)} ${a < b}")
    val list = listOf(a, b, Meters(0.25))
    println("$list ${list.sorted()} ${list.maxOrNull()} ${list.map { it.v }}")
    println("${first(list)} ${id(a)} ${id<Any>(a)}")
    println("${takeAny(a)} ${takeAny(Id(7))} ${takeNullable(null)} ${takeNullable(b)}")
    println(total(a, b))
    println("${pick(true, a, b)} ${maybe(true)} ${maybe(false)} ${elvis(null)} ${elvis(a)}")
    println("${viaWhen(0)} ${viaWhen(1)} ${viaWhen(2)} ${tryIt(true)} ${tryIt(false)}")
    println("${lambdaApply({ it + it }, a)} ${inlineApply(a) { it * 2 }}")
    val h = Holder(a, null)
    h.m = h.m + b
    h.n = h.m
    println("${h.m} ${h.n} ${h.p.x} ${h.p.y}")
    h.p = Packed(-3, 4)
    println("${h.p.x},${h.p.y}")
    val box = Box(a, Id(3), list)
    println(box)
    println(box.copy(w = b))
    val (w, i, t) = box
    println("$w $i ${t.size} ${box == Box(Meters(1.5), Id(3), listOf(a, b, Meters(0.25)))}")
    val map = hashMapOf(a to "a", b to "b")
    println("${map[Meters(1.5)]} ${map[Meters(9.0)]} ${setOf(Id(1), Id(1), Id(2)).size}")
    val shapes: List<Shape> = listOf(Square(2.0), Square(3.0))
    println("${shapes.map { it.area() }} ${shapes[0] is Square}")
    val anyM: Any = a
    if (anyM is Meters) println("smart ${anyM.v} ${anyM + b}")
    val nm: Meters? = maybe(true)
    if (nm != null) println("nonnull ${nm.v}")
    println(nm!!.half)
    var acc = Meters(0.0)
    for (m in list) acc += m
    println(acc)
    for (k in 0 until 3) acc = acc + Meters(k.toDouble())
    println(acc)
    println(runCatching { Id(-1) }.exceptionOrNull()?.message)
    println("${Id.ZERO} ${Id(5).raw}")
    val arr = arrayOf(a, b)
    println(arr[1])
    arr[0] = Meters(9.0)
    println(arr.toList())
    val plus = Meters::plus
    val value = Meters::v
    println("${plus(a, b)} ${value(a)}")
    println(listOf(a, b).fold(Meters(0.0)) { s, m -> s + m })
    println("${a.let { it.v * 10 }} ${with(b) { half }} ${a::class.simpleName}")
    val cmp: Comparable<Meters> = a
    println(cmp.compareTo(b))
    println(listOf<Any>(a, 1.5).map { it is Meters })
    println("${a.hashCode() == 1.5.hashCode()} ${(a as Any).equals(1.5)} ${a.equals(Meters(1.5))}")
    println(sequence { yield(a); yield(b + b) }.toList())
    val casted = (anyM as Meters) + a
    val safe = (viaWhen(1) as? Meters)?.v
    println("$casted $safe")
}
