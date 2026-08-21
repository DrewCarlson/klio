import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*

class T {
    @SerialInfo
    @Target(AnnotationTarget.PROPERTY, AnnotationTarget.CLASS)
    annotation class CustomAnnotation(val value: String)

    @Serializable @CustomAnnotation("sealed")
    sealed class Result { @Serializable class OK(val s: String): Result() }

    @Serializable @CustomAnnotation("object")
    object ObjectResult {}

    @Serializable
    class Holder(val r: Result, val o: ObjectResult)

    private fun List<Annotation>.getCustom(): String = "n=" + size

    fun doTest(position: Int): String {
        val desc = Holder.serializer().descriptor.getElementDescriptor(position)
        val a = desc.annotations
        println("  ann=" + a + " size=" + a.size + " cls=" + a::class.simpleName)
        val fixed: List<Annotation> = emptyList()
        println("  fixed=" + fixed.getCustom())
        return a.getCustom()
    }
}

fun main() {
    val t = T()
    println("sealed = " + t.doTest(0))
    println("object = " + t.doTest(1))
}
