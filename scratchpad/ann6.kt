import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*

class T {
    @SerialInfo
    @Target(AnnotationTarget.CLASS)
    annotation class CA(val value: String)

    @Serializable @CA("abstract")
    abstract class AbstractResult { var result: String = "" }
}

fun main() {
    val lst = kotlinx.serialization.__klsx_classAnnotations(T.AbstractResult::class)
    val arr = lst.toTypedArray()
    println("lst=" + lst + " arr.size=" + arr.size + " asList=" + arr.asList())
    val ps = PolymorphicSerializer(T.AbstractResult::class, arr)
    println("ps=" + ps)
    println("desc=" + ps.descriptor.serialName)
    println("probe=" + ps.__probeAnnotations())
    println("ann=" + ps.descriptor.annotations)
    val ps2 = PolymorphicSerializer(T.AbstractResult::class)
    println("ann2=" + ps2.descriptor.annotations)
}
