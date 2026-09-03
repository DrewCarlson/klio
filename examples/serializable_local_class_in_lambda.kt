// Run with: klio run --feature kotlinx.serialization/json examples/serializable_local_class_in_lambda.kt
// A `@Serializable` class declared inside a LAMBDA body (`42.let { data class
// Local(...) }`) or a control-flow block is a local class of the enclosing
// function like one at its top level: it gets its generated serializer and
// companion, so `Json.encodeToString(origin)` round-trips it.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

abstract class TestBase {
    // A same-named reified member in the base does not capture the library
    // `Json.encodeToString(value)` call below: that reified callee splices
    // with its own `T`, the local class.
    inline fun <reified T> Json.encodeToString(value: T, mode: Boolean): String = encodeToString(serializersModule.serializer(), value)
}

class LocalClasses : TestBase() {
    fun inLambda(): Boolean = 42.let {
        @Serializable
        data class Local(val i: Int)
        val origin = Local(it)
        val decoded: Local = Json.decodeFromString(Json.encodeToString(origin))
        origin == decoded
    }

    fun inBlock(flag: Boolean): String {
        if (flag) {
            @Serializable
            data class Inner(val s: String, val n: Int)
            return Json.encodeToString(Inner("x", 1))
        }
        return "skipped"
    }
}

fun main() {
    println(LocalClasses().inLambda())
    println(LocalClasses().inBlock(true))
}
