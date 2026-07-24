private val lock = Any()

suspend fun runCached(block: suspend () -> Any?): Any? {
    return block().also {
        synchronized(lock) {
            when {
                it == null -> println("null")
                else -> println(it)
            }
        }
    }
}

fun main() {
    println("ok")
}
