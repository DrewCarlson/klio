// A local extension function declared in one lambda and called bare from a
// nested receiver lambda must bind the call site's enclosing receiver as
// its `this` (the ktor `on(Send) { handleCall(...) }` shape).
class Sender(val tag: String) {
    fun proceed(n: Int): String = "$tag:$n"
}

fun runWith(block: Sender.(Int) -> String): String = Sender("snd").block(7)

fun install(setup: () -> Unit) = setup()

fun main() {
    var result = ""
    install {
        fun Sender.handle(a: Int, b: Boolean, c: String): String {
            val first = proceed(a)
            return "$first|$b|$c"
        }
        result = runWith { n ->
            handle(n, false, "tail")
        }
    }
    println(result)
}
