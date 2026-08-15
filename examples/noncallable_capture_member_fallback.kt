import kotlinx.coroutines.runBlocking

class Ctx3(val tag: String)

class Runner3 {
    val handlers = mutableListOf<suspend Ctx3.() -> Unit>()
    fun intercept(h: suspend Ctx3.() -> Unit) { handlers.add(h) }
    suspend fun execute(c: Ctx3) { for (h in handlers) h(c) }
}

class PipeLike3 {
    fun pipeline(): Runner3 = Runner3()

    fun run() = runBlocking {
        val pipeline = pipeline()
        pipeline.intercept {
            val secondary = pipeline()
            println("secondary made: $secondary")
        }
        pipeline.execute(Ctx3("x"))
        println("ok")
    }
}

fun main() { PipeLike3().run() }
