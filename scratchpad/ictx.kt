import kotlinx.serialization.*
import kotlinx.serialization.modules.*

interface IApiError
class ApiError : IApiError

fun main() {
    val m = SerializersModule { }
    println("module = $m")
    println("empty = " + EmptySerializersModule())
}
