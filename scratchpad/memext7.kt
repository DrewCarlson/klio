import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*

@SerialInfo
@Target(AnnotationTarget.CLASS)
annotation class CA(val value: String)

@CA("x") @Serializable
class Marked(val n: Int)

class T {
    private fun List<Annotation>.getCustom(): String = "n=" + size

    fun direct(): String = Marked.serializer().descriptor.annotations.getCustom()
    fun viaLocal(): String {
        val a: List<Annotation> = Marked.serializer().descriptor.annotations
        return a.getCustom()
    }
    fun viaInferred(): String {
        val a = Marked.serializer().descriptor.annotations
        return a.getCustom()
    }
}

fun main() {
    val t = T()
    println("local    = " + t.viaLocal())
    println("direct   = " + t.direct())
    println("inferred = " + t.viaInferred())
}
