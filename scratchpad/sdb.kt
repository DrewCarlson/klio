import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*

fun main() {
    val d = buildClassSerialDescriptor("Wrapper") {
        element("i", Int.serializer().descriptor)
    }
    println("name=" + d.serialName + " n=" + d.elementsCount + " kind=" + d.kind)
    println("elem0=" + d.getElementName(0) + " desc=" + d.getElementDescriptor(0))
}
