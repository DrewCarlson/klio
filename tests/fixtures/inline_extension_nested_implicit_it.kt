fun main() {
    val lock = Any()
    val block = { "ok" }
    val value = block().also {
        synchronized(lock) {
            println(it)
        }
    }
    println(value)
}
