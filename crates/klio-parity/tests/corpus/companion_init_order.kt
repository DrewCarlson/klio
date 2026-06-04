object Registry {
    val httpName: String = Protocol.createOrDefault("http").name
    val wsPort: Int = Protocol.createOrDefault("ws").defaultPort
}

class Protocol(val name: String, val defaultPort: Int) {
    companion object {
        val HTTP: Protocol = Protocol("http", 80)
        val WS: Protocol = Protocol("ws", 0)
        val byName: Map<String, Protocol> = listOf(HTTP, WS).associateBy { it.name }
        fun createOrDefault(n: String): Protocol = byName[n] ?: Protocol(n, -1)
    }
}

fun main() {
    println(Registry.httpName)
    println(Registry.wsPort)
    println(Protocol.createOrDefault("ftp").defaultPort)
}
