// Exercises the ktor pipeline-execution shape (DebugPipelineContext): a
// chain of `suspend Ctx.(String) -> Unit` interceptors invoked value-style
// (`ic.invoke(this, subject)`) in a proceed-nested loop, including a
// suspending interceptor that parks at `delay` and resumes mid-chain, plus
// post-`proceed` continuation work. Expected stdout is the `//>` lines.
import kotlinx.coroutines.*

typealias Interceptor = suspend PipeCtx.(String) -> Unit

class PipeCtx(private val interceptors: List<Interceptor>) {
    var subject: String = ""
    private var index = 0

    fun finish() {
        index = -1
    }

    suspend fun proceed(): String {
        val i = index
        if (i < 0) return subject
        if (i >= interceptors.size) {
            finish()
            return subject
        }
        return proceedLoop()
    }

    suspend fun proceedWith(s: String): String {
        subject = s
        return proceed()
    }

    suspend fun execute(initial: String): String {
        index = 0
        subject = initial
        return proceedLoop()
    }

    private suspend fun proceedLoop(): String {
        do {
            val i = index
            if (i == -1) break
            if (i >= interceptors.size) {
                finish()
                break
            }
            val ic = interceptors[i]
            index = i + 1
            ic.invoke(this, subject)
        } while (true)
        return subject
    }
}

fun main() = runBlocking {
    val ctx = PipeCtx(
        listOf(
            { s -> println("A in $s"); proceedWith("$s-A"); println("A out " + subject) },
            { s -> println("B in $s"); delay(10); println("B resumed"); proceedWith("$s-B") },
            { s -> println("C in $s"); proceedWith("$s-C") }
        )
    )
    println("final=" + ctx.execute("start"))
    //> A in start
    //> B in start-A
    //> B resumed
    //> C in start-A-B
    //> A out start-A-B-C
    //> final=start-A-B-C
}
