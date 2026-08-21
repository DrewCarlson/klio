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

    @Serializable @CustomAnnotation("object")
    object ObjectResult {}

    @Serializable
    class Holder(val r: Result, val a: AbstractResult, val o: ObjectResult)
}

fun main() {
    println("classes=" + kotlinx.serialization.__klsx_ctorParamClasses(T.Holder::class))
    println("types=" + kotlinx.serialization.__klsx_ctorParamTypes(T.Holder::class))
    println("isK=" + (kotlinx.serialization.__klsx_ctorParamClasses(T.Holder::class).map { it is kotlin.reflect.KClass<*> }))
    println("gen0=" + kotlinx.serialization.__klsx_generatedSerializer(T.Result::class))
    println("resAnn=" + kotlinx.serialization.__klsx_classAnnotations(T.Result::class))
    val d = T.Holder.serializer().descriptor
    for (i in 0 until d.elementsCount) {
        val e = d.getElementDescriptor(i)
        println("$i " + d.getElementName(i) + " -> " + e.serialName + " kind=" + e.kind + " ann=" + e.annotations)
    }
}
