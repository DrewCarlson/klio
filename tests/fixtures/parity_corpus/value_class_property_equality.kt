// `==` between values of a value class and of a data class compares their
// properties as the properties' own `equals` does: a NaN equals itself and
// -0.0 is not 0.0, where `==` on the primitives themselves is IEEE.

@JvmInline
value class Meters(val v: Double)

@JvmInline
value class Ratio(val f: Float)

@JvmInline
value class Id(val n: Int)

@JvmInline
value class Name(val s: String)

@JvmInline
value class Packed(val bits: ULong)

@JvmInline
value class Wrap<T>(val t: T)

data class Point(val x: Double, val y: Int)

data class Pair2(val a: Long, val b: Char)

fun same(a: Meters, b: Meters) = a == b
fun maybe(a: Meters?, b: Meters?) = a == b
fun asAny(a: Any, b: Any) = a == b

fun main() {
    val nan = Double.NaN
    println("meters ${Meters(1.5) == Meters(1.5)} ${Meters(1.5) == Meters(2.5)} ${Meters(nan) == Meters(nan)} ${Meters(0.0) == Meters(-0.0)}")
    println("ieee ${nan == nan} ${0.0 == -0.0}")
    println("ratio ${Ratio(Float.NaN) == Ratio(Float.NaN)} ${Ratio(0f) == Ratio(-0f)} ${Ratio(2f) != Ratio(3f)}")
    println("id ${Id(3) == Id(3)} ${Id(3) != Id(4)}")
    println("name ${Name("a" + "b") == Name("ab")} ${Name("a") == Name("b")}")
    println("packed ${Packed(5uL) == Packed(5uL)} ${Packed(5uL) == Packed(ULong.MAX_VALUE)}")
    println("wrap ${Wrap(listOf(1, 2)) == Wrap(listOf(1, 2))} ${Wrap<Any?>(null) == Wrap<Any?>(null)} ${Wrap(1) == Wrap(2)}")
    println("fun ${same(Meters(nan), Meters(nan))} ${maybe(null, null)} ${maybe(Meters(1.0), null)} ${maybe(Meters(nan), Meters(nan))}")
    println("any ${asAny(Meters(1.0), Meters(1.0))} ${asAny(Meters(1.0), Id(1))} ${asAny(Meters(0.0), Meters(-0.0))}")
    println("unsigned ${5u == 5u} ${7uL == 7uL} ${(-1).toUInt() == UInt.MAX_VALUE}")
    println("point ${Point(nan, 1) == Point(nan, 1)} ${Point(0.0, 1) == Point(-0.0, 1)} ${Point(1.0, 1) == Point(1.0, 2)}")
    println("pair ${Pair2(1L, 'a') == Pair2(1L, 'a')} ${Pair2(1L, 'a') == Pair2(1L, 'b')}")
    val ms = listOf(Meters(1.0), Meters(nan))
    println("list ${ms.contains(Meters(nan))} ${ms.indexOf(Meters(1.0))} ${setOf(Meters(-0.0), Meters(0.0)).size}")
    println("hash ${Meters(1.5).hashCode() == 1.5.hashCode()} ${Point(1.0, 2).hashCode() == Point(1.0, 2).hashCode()}")
}
