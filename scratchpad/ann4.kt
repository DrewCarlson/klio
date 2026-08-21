import kotlinx.serialization.*
import kotlin.reflect.KClass

class T {
    @SerialInfo
    @Target(AnnotationTarget.PROPERTY, AnnotationTarget.CLASS)
    annotation class CustomAnnotation(val value: String)

    @Serializable @CustomAnnotation("sealed")
    sealed class Result { @Serializable class OK(val s: String): Result() }

    @Serializable
    class HolderA(val r: Result)
}

fun main() {
    val cs = kotlinx.serialization.__klsx_ctorParamClasses(T.HolderA::class)
    val c0 = cs[0]
    println("c0=" + c0 + " isK=" + (c0 is KClass<*>))
    println("isSer=" + kotlinx.serialization.__klsx_isSerializable(c0))
    if (c0 is KClass<*>) {
        val s = kotlinx.serialization.__klsx_generatedSerializer(c0)
        println("s=" + s)
        println("desc=" + s?.descriptor?.serialName)
    }
    println("same=" + (c0 == T.Result::class))
}
