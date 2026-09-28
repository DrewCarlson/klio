import kotlin.jvm.JvmInline
import kotlin.time.TimeSource

// The cost of one operation of each kind the interpreter executes: calls,
// field access, allocation, value classes, lambdas, collections, strings
// and arithmetic. Each case runs a counted loop and prints nanoseconds per
// iteration, the loop included; `loop_ns` is the loop alone. Each case is a
// function of its own, so a change to one case's code leaves the others'
// registers and code where they were.

var sink = 0L
const val N = 2_000_000

inline fun bench(name: String, n: Int, body: (Int) -> Unit) {
    val t = TimeSource.Monotonic.markNow()
    for (i in 0 until n) body(i)
    val ns = t.elapsedNow().inWholeNanoseconds.toDouble() / n
    println("${name}_ns=${(ns * 100).toLong() / 100.0}")
}

fun inc(x: Int): Int = x + 1
fun five(a: Int, b: Int, c: Int, d: Int, e: Int): Int = a + b + c + d + e

class Counter(var count: Int) {
    fun add(d: Int): Int {
        count += d
        return count
    }
}

abstract class Shape {
    abstract fun area(): Int
    abstract val sides: Int
}

class Square(val side: Int) : Shape() {
    override fun area() = side * side
    override val sides: Int get() = 4
}

class Rect(val w: Int, val h: Int) : Shape() {
    override fun area() = w * h
    override val sides: Int get() = 4
}

interface Sized {
    fun size(): Int
}

class Box(val n: Int) : Sized {
    override fun size() = n
}

class Tall(val n: Int) : Sized {
    override fun size() = n * 2
}

class Point(val x: Int, val y: Int)

@JvmInline
value class Rgb(val packed: Long) {
    val red: Int get() = ((packed shr 16) and 0xFF).toInt()
    val green: Int get() = ((packed shr 8) and 0xFF).toInt()
    fun brighter(): Rgb = Rgb(packed or 0x101010L)
}

@JvmInline
value class Meters(val value: Float) {
    operator fun plus(other: Meters) = Meters(value + other.value)
}

fun loop() {
    var acc = 0L
    bench("loop", N) { acc += it }
    sink += acc
}

fun staticCall() {
    var acc = 0L
    bench("static_call", N) { acc += inc(it) }
    bench("static_call_5_args", N) { acc += five(it, 1, 2, 3, 4) }
    sink += acc
}

fun memberCalls() {
    var acc = 0L
    val counter = Counter(0)
    bench("member_call", N) { acc += counter.add(1) }
    val shapes = arrayOf<Shape>(Square(2), Rect(2, 3))
    bench("virtual_call", N) { acc += shapes[it and 1].area() }
    bench("virtual_getter", N) { acc += shapes[it and 1].sides }
    val sized = arrayOf<Sized>(Box(1), Tall(2))
    bench("interface_call", N) { acc += sized[it and 1].size() }
    sink += acc
}

fun fields() {
    var acc = 0L
    val p = Point(3, 4)
    bench("field_read", N) { acc += p.x }
    val counter = Counter(0)
    bench("field_write", N) { counter.count = it }
    sink += acc + counter.count
}

fun allocation() {
    var acc = 0L
    bench("alloc_object", N) { acc += Point(it, 1).x }
    bench("alloc_int_array", N) { acc += IntArray(4).size }
    sink += acc
}

fun valueClasses() {
    var acc = 0L
    bench("value_class_make", N) { acc += Rgb(it.toLong()).red }
    bench("value_class_method", N) { acc += Rgb(it.toLong()).brighter().green }
    bench("value_class_equals", N) { if (Rgb(it.toLong()) == Rgb((it and 3).toLong())) acc++ }
    var m = Meters(0f)
    bench("value_class_float_op", N) { m += Meters(1f) }
    var u = 1uL
    bench("ulong_ops", N) { u = (u shl 1) xor it.toULong() }
    sink += acc + m.value.toLong() + u.toLong()
}

fun lambdas() {
    var acc = 0L
    val f: (Int) -> Int = { it * 2 }
    bench("lambda_call", N) { acc += f(it) }
    bench("boxed_int", N) {
        val a: Any = it
        acc += a as Int
    }
    sink += acc
}

fun arithmetic() {
    var l = 1L
    bench("long_math", N) { l = l * 31 + it }
    var d = 1.0
    bench("double_math", N) { d = d * 1.0000001 + 0.5 }
    var acc = 0L
    bench("branch_when", N) {
        acc += when (it and 7) {
            0 -> 1
            1, 2 -> 2
            3 -> 3
            else -> 4
        }
    }
    sink += l + d.toLong() + acc
}

fun collections() {
    var acc = 0L
    val arr = IntArray(1024) { it }
    bench("array_read", N) { acc += arr[it and 1023] }
    val list = ArrayList<Int>()
    for (i in 0 until 1024) list.add(i)
    bench("list_get", N) { acc += list[it and 1023] }
    val map = HashMap<Int, Int>()
    for (i in 0 until 1024) map[i] = i
    bench("map_get_int", N) { acc += map[it and 1023]!! }
    val keys = Array(1024) { Point(it, it) }
    val objMap = HashMap<Point, Int>()
    for (k in keys) objMap[k] = k.x
    bench("map_get_object", N) { acc += objMap[keys[it and 1023]]!! }
    sink += acc
}

fun strings() {
    var acc = 0L
    val sb = StringBuilder()
    bench("string_builder", N) {
        if (sb.length > 4096) sb.setLength(0)
        sb.append(it and 63)
    }
    bench("string_template", N / 4) { acc += "v=$it;".length }
    sink += acc + sb.length
}

fun main() {
    loop()
    staticCall()
    memberCalls()
    fields()
    allocation()
    valueClasses()
    lambdas()
    arithmetic()
    collections()
    strings()
    println("sink=$sink")
}
