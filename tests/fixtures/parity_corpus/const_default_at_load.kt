// A primary-constructor default that references a top-level `const val`
// (`class Server(val port: Int = DEFAULT_PORT)`) must resolve the constant
// even when the class is constructed by a companion/object initializer at
// load time — `const val` is a compile-time constant, available before the
// global slot for the property is set. ktor's `URLBuilder.Companion`
// constructs `Url(origin)` (whose port defaults to `DEFAULT_PORT`) this way.
const val DEFAULT_PORT: Int = 8080

class Server(val port: Int = DEFAULT_PORT) {
    init { require(port in 0..65535) { "bad port $port" } }
    companion object {
        val default: Server = Server()
    }
}

fun main() {
    println(Server.default.port)
    println(Server().port)
    println(Server(443).port)
}
