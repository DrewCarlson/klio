import kotlinx.serialization.*
import kotlinx.serialization.modules.*
import kotlin.reflect.*

interface IApiError { val code: Int }

object MySer : KSerializer<IApiError> {
    override val descriptor: kotlinx.serialization.descriptors.SerialDescriptor
        get() = kotlinx.serialization.descriptors.buildClassSerialDescriptor("IApiError")
    override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: IApiError) {}
    override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): IApiError = throw NotImplementedError()
}

fun main() {
    val module = serializersModuleOf(IApiError::class, MySer)
    println("module=" + module)
    val s = module.serializer(typeOf<IApiError>())
    println("s=" + s)
}
