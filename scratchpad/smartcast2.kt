sealed class Provider {
    class Argless(val serializer: String) : Provider()
    class WithArgs(val f: () -> String) : Provider()
}

fun serializer(): String = "GLOBAL"

fun take(k: String, s: String) = println("argless:$k:$s")
fun take(k: String, f: () -> String) = println("withargs:$k:${f()}")

fun main() {
    val m: Map<String, Provider> = mapOf("a" to Provider.Argless("s"), "b" to Provider.WithArgs { "t" })
    m.forEach { (k, serial) ->
        when (serial) {
            is Provider.Argless -> take(k, serial.serializer)
            is Provider.WithArgs -> take(k, serial.f)
        }
    }
}
