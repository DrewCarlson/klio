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
}

fun main() {
    println("isSer(Result)=" + kotlinx.serialization.__klsx_isSerializable(T.Result::class))
    println("sealedSubs=" + T.Result::class.sealedSubclasses)
    val s = kotlinx.serialization.__klsx_generatedSerializer(T.Result::class)
    println("gen(Result)=" + s)
    println("desc=" + s?.descriptor?.serialName + " ann=" + s?.descriptor?.annotations)
    val p = kotlinx.serialization.__klsx_generatedSerializer(T.AbstractResult::class)
    println("gen(Abstract)=" + p + " ann=" + p?.descriptor?.annotations)
    val o = kotlinx.serialization.__klsx_generatedSerializer(T.ObjectResult::class)
    println("gen(Object)=" + o + " ann=" + o?.descriptor?.annotations)
}
