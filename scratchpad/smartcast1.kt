sealed class Provider {
    class Argless(val serializer: String) : Provider()
    class WithArgs(val f: () -> String) : Provider()
}

fun serializer(): String = "GLOBAL"

fun show(p: Provider): String = when (p) {
    is Provider.Argless -> "argless:" + p.serializer
    is Provider.WithArgs -> "withargs:" + p.f()
}

fun main() {
    println(show(Provider.Argless("s")))
    println(show(Provider.WithArgs { "t" }))
}
