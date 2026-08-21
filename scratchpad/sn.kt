import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*

@Serializable
@SerialName("Renamed")
class Wrapper(val i: Int)

@Serializable
class Plain(val i: Int)

@Serializable
class WithFields(@SerialName("other") val i: Int)

fun main() {
    println("class  @SerialName : " + Wrapper.serializer().descriptor.serialName)
    println("class  default     : " + Plain.serializer().descriptor.serialName)
    println("field  @SerialName : " + WithFields.serializer().descriptor.getElementName(0))
}
