import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*

@SerialInfo
@Target(AnnotationTarget.CLASS)
annotation class CA(val value: String)

@CA("x") class Marked

class Target

fun main() {
    val anns = __klsx_classAnnotations(Marked::class)
    println("anns=" + anns)

    val d1 = buildSerialDescriptor("A", PolymorphicKind.OPEN) {
        annotations = anns
    }
    println("d1=" + d1.annotations)

    val d2 = buildSerialDescriptor("B", PolymorphicKind.OPEN) {
        element("type", String.serializer().descriptor)
        annotations = anns
    }
    println("d2=" + d2.annotations)

    val d3 = buildSerialDescriptor("C", PolymorphicKind.OPEN) {
        element("type", String.serializer().descriptor)
        element("value", buildSerialDescriptor("C.inner", SerialKind.CONTEXTUAL))
        annotations = anns
    }
    println("d3=" + d3.annotations)
}
