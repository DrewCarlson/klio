import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*

class T {
    @SerialInfo
    @Target(AnnotationTarget.PROPERTY, AnnotationTarget.CLASS)
    annotation class CustomAnnotation(val value: String)

    @Serializable @CustomAnnotation("sealed")
    sealed class Result { @Serializable class OK(val s: String): Result() }

    @Serializable @CustomAnnotation("abstract")
    abstract class AbstractResult { var result: String = "" }

    @Serializable
    class HolderA(val r: Result)
    @Serializable
    class HolderB(val a: AbstractResult)
}

fun main() {
    val da = T.HolderA.serializer().descriptor
    println("A0 " + da.getElementDescriptor(0).serialName)
    val db = T.HolderB.serializer().descriptor
    println("B0 " + db.getElementDescriptor(0).serialName)

    val arr = kotlinx.serialization.__klsx_classAnnotations(T.AbstractResult::class).toTypedArray()
    println("arr=" + arr.size)
    val ps = PolymorphicSerializer(T.AbstractResult::class, arr)
    println("ps ann=" + ps.descriptor.annotations)
}
