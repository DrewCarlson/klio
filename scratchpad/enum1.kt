import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*

@SerialInfo
@Target(AnnotationTarget.CLASS, AnnotationTarget.PROPERTY)
annotation class SerialAnnotation(val text: String)

@SerialAnnotation("On Class")
@Serializable
enum class FullyAnnotatedEnum {
    @SerialAnnotation("On A") A,
    @SerialAnnotation("On B") B
}

fun main() {
    val d = FullyAnnotatedEnum.serializer().descriptor
    println("name=" + d.serialName)
    println("classAnn=" + d.annotations.size + " " + d.annotations)
    println("e0=" + d.getElementName(0) + " ann=" + d.getElementAnnotations(0).size)
    println("e1=" + d.getElementName(1) + " ann=" + d.getElementAnnotations(1).size)
}
