import kotlinx.serialization.*

@Serializable
class A(val i: Int)

fun main() {
    val s = A.serializer()
    println("class = " + s::class.simpleName)
    println("is KSerializer = " + (s is KSerializer<*>))
    println("is SerializationStrategy = " + (s is SerializationStrategy<*>))
}
