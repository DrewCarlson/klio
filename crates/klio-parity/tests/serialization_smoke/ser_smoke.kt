// Serialization smoke: drives the reflection-synthesized KSerializer
// (the kotlinx-serialization compiler-plugin replacement) and the
// klioMain primitive serializers through the real klio binary, using
// a tiny in-program flat-list Encoder/Decoder built on the upstream
// AbstractEncoder / AbstractDecoder (consumed verbatim from the
// kotlinx-serialization-core submodule). Also round-trips datetime's
// LocalDate / Instant value types reflectively, proving the
// datetime <-> serialization pack dependency. Expected stdout is the
// leading run of `//> ` lines.
//
//> p_enc=[7, kt]
//> p_rt=true
//> n_enc=[hello, null, 3]
//> n_rt=true
//> ld_enc=[2024, 2, 29]
//> ld_rt=true
//> inst_enc=[1700000000, 0]
//> inst_rt=true
//> prim=kotlin.Int/kotlin.String

import kotlinx.serialization.Serializable
import kotlinx.serialization.KSerializer
import kotlinx.serialization.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.AbstractEncoder
import kotlinx.serialization.encoding.AbstractDecoder
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.datetime.LocalDate
import kotlinx.datetime.Instant

@Serializable
class P(val a: Int, val b: String)

@Serializable
class N(val s: String, val maybe: String?, val n: Int)

class ListEncoder(val out: ArrayList<Any?>) : AbstractEncoder() {
    override fun encodeValue(value: Any) { out.add(value) }
    override fun encodeNull() { out.add(null) }
}

class ListDecoder(val values: List<Any?>) : AbstractDecoder() {
    private var idx = 0
    private var elem = 0
    override fun decodeValue(): Any { val v = values[idx]!!; idx += 1; return v }
    override fun decodeNotNullMark(): Boolean = values[idx] != null
    override fun decodeNull(): Nothing? { idx += 1; return null }
    override fun decodeElementIndex(descriptor: SerialDescriptor): Int {
        if (elem >= descriptor.elementsCount) return CompositeDecoder.DECODE_DONE
        val r = elem; elem += 1; return r
    }
}

fun <T> roundtrip(ser: KSerializer<T>, value: T): Pair<ArrayList<Any?>, T> {
    val buf = ArrayList<Any?>()
    ser.serialize(ListEncoder(buf), value)
    val back = ser.deserialize(ListDecoder(buf))
    return Pair(buf, back)
}

fun main() {
    val ps = P.serializer()
    val p = P(7, "kt")
    val (penc, pback) = roundtrip(ps, p)
    println("p_enc=$penc")
    println("p_rt=${pback.a == p.a && pback.b == p.b}")

    val ns = N.serializer()
    val n = N("hello", null, 3)
    val (nenc, nback) = roundtrip(ns, n)
    println("n_enc=$nenc")
    println("n_rt=${nback.s == n.s && nback.maybe == n.maybe && nback.n == n.n}")

    val ld = LocalDate(2024, 2, 29)
    val lds = serializer<LocalDate>()
    val (ldenc, ldback) = roundtrip(lds, ld)
    println("ld_enc=$ldenc")
    println("ld_rt=${ldback.year == ld.year && ldback.monthNumber == ld.monthNumber && ldback.dayOfMonth == ld.dayOfMonth}")

    val inst = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    val insts = serializer<Instant>()
    val (ienc, iback) = roundtrip(insts, inst)
    println("inst_enc=$ienc")
    println("inst_rt=${iback.toEpochMilliseconds() == inst.toEpochMilliseconds()}")

    val pi = serializer<Int>().descriptor.serialName
    val pstr = serializer<String>().descriptor.serialName
    println("prim=$pi/$pstr")
}
