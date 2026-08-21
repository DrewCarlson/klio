import kotlinx.serialization.*
import kotlinx.serialization.modules.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*

interface IApiError
@Serializable
class ApiError(val code: Int) : IApiError

object CustomSer : KSerializer<IApiError> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("IApiError", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: IApiError) { encoder.encodeString("x") }
    override fun deserialize(decoder: Decoder): IApiError = ApiError(0)
}

fun main() {
    val m = SerializersModule { contextual(IApiError::class, CustomSer) }
    println("getContextual = " + m.getContextual(IApiError::class))
    println("serializer    = " + m.serializer<IApiError>())
}
