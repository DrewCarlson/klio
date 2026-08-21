// The kotlinx plugin serializes BODY properties too, after the constructor
// ones: every property with a backing field, in declaration order, skipping
// delegated and @Transient ones. A property whose accessors never read
// `field` has no backing field and is not an element; one with an
// initializer is an optional element; one assigned only in an `init` block
// keeps the init block's value on decode.
//
// Run with: klio run examples/serializable_body_properties.kt

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.serializer
import kotlinx.serialization.Transient
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.AbstractDecoder
import kotlinx.serialization.encoding.AbstractEncoder
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.serialization.modules.EmptySerializersModule
import kotlinx.serialization.modules.SerializersModule

@Serializable
class Session(val user: String) {
    var visits: Int = 0
    val label = "session"
    var note: String
    @Transient
    var cache: String = "skipped"
    val display: String
        get() = "$user/$visits"

    init {
        note = "fresh"
    }
}

class RecordingEncoder : AbstractEncoder() {
    override val serializersModule: SerializersModule = EmptySerializersModule()
    val out = ArrayList<String>()
    override fun encodeValue(value: Any) { out.add(value.toString()) }
}

class CountingDecoder(private val elementCount: Int) : AbstractDecoder() {
    override val serializersModule: SerializersModule = EmptySerializersModule()
    private var elementIndex = 0
    override fun decodeString(): String = "decoded$elementIndex"
    override fun decodeInt(): Int = 40 + elementIndex
    override fun decodeElementIndex(descriptor: SerialDescriptor): Int {
        if (elementIndex == elementCount) return CompositeDecoder.DECODE_DONE
        return elementIndex++
    }
}

fun main() {
    val ser: KSerializer<Session> = Session.serializer()
    val d = ser.descriptor
    println("elements = " + d.elementsCount)
    var i = 0
    while (i < d.elementsCount) {
        println("  " + d.getElementName(i) + " optional=" + d.isElementOptional(i))
        i++
    }

    val enc = RecordingEncoder()
    val s = Session("ada")
    s.visits = 7
    ser.serialize(enc, s)
    println("encoded  = " + enc.out)

    val v = ser.deserialize(CountingDecoder(4))
    println("user     = " + v.user)
    println("visits   = " + v.visits)
    println("label    = " + v.label)
    println("note     = " + v.note)
    println("cache    = " + v.cache)
    println("display  = " + v.display)
}
