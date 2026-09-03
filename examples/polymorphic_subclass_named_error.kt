// Run with: klio run --feature kotlinx.serialization/json examples/polymorphic_subclass_named_error.kt
// A polymorphic subclass named `Error` (nested in a sealed parent) registers
// under ITS class, not `kotlin.Error`: the reified `T` that
// `subclass(ApiResponse.Error.serializer())` reads off the factory's receiver
// keeps the nested qualification, so open polymorphism over a non-serializable
// base finds the subclass by value and by discriminator.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

class Api {
    sealed class ApiResponse {
        @Serializable @SerialName("ApiError")
        object Error : ApiResponse()
        @Serializable @SerialName("ApiResponse")
        data class Response(val message: String) : ApiResponse()
    }

    @Serializable
    data class ApiCarrier(@Polymorphic val response: ApiResponse)

    val json = Json {
        serializersModule = SerializersModule {
            polymorphic(ApiResponse::class) {
                subclass(ApiResponse.Error.serializer())
                subclass(ApiResponse.Response.serializer())
            }
        }
    }

    fun roundTrip(carrier: ApiCarrier): String {
        val text = json.encodeToString(ApiCarrier.serializer(), carrier)
        return "$text -> ${json.decodeFromString(ApiCarrier.serializer(), text) == carrier}"
    }
}

fun main() {
    val api = Api()
    println(api.roundTrip(Api.ApiCarrier(Api.ApiResponse.Error)))
    println(api.roundTrip(Api.ApiCarrier(Api.ApiResponse.Response("OK"))))
}
