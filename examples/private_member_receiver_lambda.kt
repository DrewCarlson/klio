// Run with: klio run --feature kotlinx.serialization/json examples/private_member_receiver_lambda.kt
// A bare call to a PRIVATE member whose parameter is a receiver lambda
// (`builder: PolymorphicModuleBuilder<Any>.() -> Unit`) gives the lambda its
// declared receiver, so a reified extension called inside it
// (`subclass(Int::class)`) resolves against that receiver and binds `T`
// statically, exactly as the same call through a public member does.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

class Registry {
    fun build(): List<String> {
        val out = ArrayList<String>()
        out += describe(false) { subclass(Int::class) }
        out += describe(true) { subclass(String::class) }
        return out
    }

    private fun describe(arrays: Boolean, builder: PolymorphicModuleBuilder<Any>.() -> Unit): String {
        return try {
            val json = Json {
                useArrayPolymorphism = arrays
                serializersModule = SerializersModule { polymorphic(Any::class) { builder() } }
            }
            "arrays=$arrays: ok (${json.configuration.useArrayPolymorphism})"
        } catch (e: IllegalArgumentException) {
            "arrays=$arrays: rejected primitive"
        }
    }
}

fun main() {
    for (line in Registry().build()) println(line)
}
