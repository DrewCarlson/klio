// Conversions between the primitive numbers and Char, arithmetic between
// operands of different types, and Long shifts, at their edges: narrowing
// keeps the low bits, a floating value saturates and NaN converts to 0, a
// mixed operation computes in the promoted type.

fun conversions() {
    val longs = longArrayOf(0L, -1L, 0x7FFF_FFFFL, 0x8000_0000L, 0x1_0000_FFFFL, Long.MIN_VALUE, Long.MAX_VALUE)
    for (l in longs) {
        println("L $l ${l.toInt()} ${l.toShort()} ${l.toByte()} ${l.toInt().toChar().code} ${l.toFloat()} ${l.toDouble()}")
    }
    val ints = intArrayOf(0, -1, 127, 128, 255, 256, 32767, 32768, 65535, 65536, Int.MIN_VALUE, Int.MAX_VALUE)
    for (i in ints) {
        println("I $i ${i.toLong()} ${i.toShort()} ${i.toByte()} ${i.toChar().code} ${i.toFloat()} ${i.toDouble()}")
    }
    val doubles = doubleArrayOf(0.0, -0.0, 1.9, -1.9, 3.0e9, -3.0e9, 1.0e19, -1.0e19, Double.NaN,
        Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 1.0e40, 0.1)
    for (d in doubles) {
        println("D $d ${d.toInt()} ${d.toLong()} ${d.toFloat()}")
    }
    val floats = floatArrayOf(0.5f, -2.5f, 3.0e9f, -3.0e9f, 1.0e19f, Float.NaN, Float.NEGATIVE_INFINITY)
    for (f in floats) {
        println("F $f ${f.toInt()} ${f.toLong()} ${f.toDouble()}")
    }
    val b: Byte = -3
    val s: Short = -300
    val c = 'Z'
    println("B ${b.toInt()} ${b.toLong()} ${b.toShort()} ${b.toFloat()} ${b.toDouble()}")
    println("S ${s.toInt()} ${s.toLong()} ${s.toByte()} ${s.toFloat()}")
    println("C ${c.code} ${c.code.toLong()} ${(c.code + 1).toChar()}")
}

fun mixed() {
    val b1: Byte = 100
    val b2: Byte = 100
    val sum: Any = b1 + b2
    println("byte+byte ${sum} ${sum is Int}")
    val s1: Short = 30000
    val prod: Any = s1 * s1
    println("short*short ${prod} ${prod is Int}")
    val i = 7
    val l = 3_000_000_000L
    val il: Any = i + l
    val li: Any = l - i
    println("int+long ${il} ${il is Long} ${li} ${li is Long}")
    println("long/int ${l / i} ${l % i} ${-l / i} ${-l % i}")
    val ifl: Any = i * 1.5f
    println("int*float ${ifl} ${ifl is Float}")
    println("long+float ${l + 0.5f}")
    val idb: Any = i + 0.25
    println("int+double ${idb} ${idb is Double}")
    println("float+double ${0.1f + 0.2}")
    println("byte*long ${b1 * l}")
    var acc = 0L
    for (k in 0 until 10) acc += k
    println("acc $acc")
    var total = 0.0
    for (k in 1..4) total += k
    println("total $total")
}

fun comparisons() {
    val i = 5
    val l = 5_000_000_000L
    println("${i < l} ${l > i} ${i.toLong() == 5L} ${i <= 5L}")
    val b: Byte = -1
    val b2: Byte = 1
    println("${b < b2} ${b > b2} ${b.compareTo(b2)}")
    val c1 = 'a'
    val c2 = 'b'
    println("${c1 < c2} ${c2 >= c1} ${c1.compareTo(c2)}")
    println("${1 < Double.NaN} ${1 > Double.NaN} ${1.compareTo(Double.NaN)} ${2.compareTo(2.0f)}")
    println("${3L < 2.5f} ${3L.compareTo(3.0)} ${(-0.0).compareTo(0)} ${0.compareTo(-0.0f)}")
}

fun shifts() {
    val x = -0x1234_5678_9ABCL
    for (n in intArrayOf(0, 1, 31, 32, 63, 64, 65, -1)) {
        println("<< $n ${x shl n} >> ${x shr n} >>> ${x ushr n}")
    }
    val i = -0x1234
    println("int ${i shl 33} ${i shr 33} ${i ushr 33}")
}

fun main() {
    conversions()
    mixed()
    comparisons()
    shifts()
}
