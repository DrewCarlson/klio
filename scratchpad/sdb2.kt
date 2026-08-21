import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*

@Serializable
@SerialName("Wrapper")
class Wrapper(val i: Int)

fun main() {
    val gen = Wrapper.serializer().descriptor
    val man = buildClassSerialDescriptor("Wrapper") { element("i", Int.serializer().descriptor) }
    println("gen n=" + gen.elementsCount + " man n=" + man.elementsCount)
    println("gen name=" + gen.serialName + " kind=" + gen.kind + " nullable=" + gen.isNullable)
    println("gen ann=" + gen.annotations + " man ann=" + man.annotations)
    println("gen e0=" + gen.getElementName(0) + " man e0=" + man.getElementName(0))
    println("gen d0=" + gen.getElementDescriptor(0) + " man d0=" + man.getElementDescriptor(0))
    println("gen a0=" + gen.getElementAnnotations(0))
    println("man a0=" + man.getElementAnnotations(0))
    println("gen opt0=" + gen.isElementOptional(0) + " man opt0=" + man.isElementOptional(0))
}
