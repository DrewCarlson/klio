import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.jvm.JvmInline

// Value classes over numbers through members and functions of every kind:
// an interface whose method takes the class, implemented by a class and by
// an object; a fun interface; callable references; delegation by an
// interface; suspend functions; extension and local functions; defaults
// and named arguments; a captured var; arrays; string concatenation;
// nullable fields and safe calls; a when subject tested by type; a
// construction that initializes the class's companion.

@JvmInline
value class Px(val raw: Int) {
    operator fun plus(o: Px) = Px(raw + o.raw)
    operator fun compareTo(o: Px) = raw.compareTo(o.raw)
    override fun toString() = "${raw}px"
}

@JvmInline
value class Angle(val deg: Float) {
    val radians: Float get() = deg * 0.017453292f
}

interface Measurer {
    fun measure(width: Px, pad: Px = Px(1)): Px
    val minimum: Px
}

class Doubler : Measurer {
    override fun measure(width: Px, pad: Px): Px = Px(width.raw * 2) + pad
    override val minimum: Px = Px(4)
}

object Fixed : Measurer {
    override fun measure(width: Px, pad: Px) = Px(10)
    override val minimum get() = Px(0)
}

class Wrapped(inner: Measurer) : Measurer by inner

fun interface PxTransform {
    fun apply(p: Px): Px
}

fun Px.twice() = this + this
fun Px?.orZero(): Px = this ?: Px(0)

fun scale(p: Px, times: Int = 3, extra: Px = Px(0)): Px {
    fun inner(q: Px): Px = Px(q.raw * times)
    return inner(p) + extra
}

suspend fun slowAdd(a: Px, b: Px): Px = a + b

fun runSuspend(block: suspend () -> Px): Px {
    var out: Px? = null
    block.startCoroutine(Continuation(EmptyCoroutineContext) { result -> out = result.getOrThrow() })
    return out!!
}

@JvmInline
value class Tagged(val n: Int) {
    companion object {
        init {
            println("Tagged companion ready")
        }
        val UNIT get() = Tagged(1)
    }
}

class Holder(var p: Px?, var angle: Angle)

fun describe(x: Any): String = when (x) {
    is Px -> "px ${x.raw}"
    is Angle -> "angle ${x.deg}"
    else -> "other"
}

fun main() {
    val ms: List<Measurer> = listOf(Doubler(), Fixed, Wrapped(Doubler()))
    println(ms.map { it.measure(Px(5)) } + ms.map { it.measure(Px(5), Px(0)) } + ms.map { it.minimum })
    val t = PxTransform { it + Px(100) }
    val tr: PxTransform = PxTransform(Px::twice)
    println("${t.apply(Px(1))} ${tr.apply(Px(21))}")
    val f: (Px) -> Px = Px::twice
    val g = ::scale
    val h: (Px, Px) -> Px = Px::plus
    println("${f(Px(3))} ${g(Px(2), 2, Px(1))} ${h(Px(1), Px(2))}")
    println("${scale(Px(2))} ${scale(Px(2), extra = Px(5))} ${scale(times = 4, p = Px(1))}")
    println("${Px(7).twice()} ${null.orZero()} ${Px(3).orZero()}")
    println(runSuspend { slowAdd(Px(20), Px(22)) })
    var total = Px(0)
    listOf(1, 2, 3).forEach { total += Px(it) }
    val add = { d: Int -> total = total + Px(d) }
    add(10)
    println(total)
    val arr = Array(3) { Px(it * 5) }
    arr[1] = arr[1] + Px(1)
    println("${arr.toList()} ${arr.maxByOrNull { it.raw }} ${arr.sortedBy { -it.raw }}")
    println("total: " + total + ", angle: " + Angle(90f).radians)
    val holder = Holder(null, Angle(45f))
    println("${holder.p?.raw} ${holder.p?.twice()} ${holder.angle.deg}")
    holder.p = Px(8)
    holder.angle = Angle(holder.angle.deg * 2)
    println("${holder.p?.raw} ${holder.p?.twice()} ${holder.angle.deg} ${holder.angle.radians}")
    println(listOf<Any>(Px(1), Angle(2f), "x").map { describe(it) })
    println("${Px(3) < Px(4)} ${maxOf(Px(3), Px(9), compareBy { it.raw })} ${listOf(Px(2), Px(1)).sortedWith(compareBy { it.raw })}")
    val grouped = listOf(Px(1), Px(2), Px(1)).groupBy { it }
    println("${grouped.keys} ${grouped[Px(1)]?.size}")
    val m = mutableMapOf<String, Px>()
    m.getOrPut("a") { Px(5) }
    m["b"] = m.getValue("a") + Px(1)
    println(m)
    println("before")
    val tagged = Tagged(3)
    println("after ${tagged.n} ${Tagged.UNIT.n}")
}
