// `a ?: b` infers one type for both sides, so a lambda or callable
// reference on the right takes its parameter types from the function type
// on the left: `config.filter ?: { call -> ... }` types `call` as a `Call`.
class Origin(val scheme: String, val port: Int)
class Req(val origin: Origin)
class Call(val request: Req)

class Config { var filter: ((Call) -> Boolean)? = null }

fun isPlain(call: Call): Boolean = call.request.origin.scheme == "http"

fun main() {
    val config = Config()
    val secure = config.filter ?: { call ->
        call.request.origin.run { scheme == "https" && port == 443 }
    }
    println(secure(Call(Req(Origin("https", 443)))))
    println(secure(Call(Req(Origin("https", 8443)))))
    val byPort = config.filter ?: { call -> call.request.origin.port == 80 }
    println(byPort(Call(Req(Origin("http", 80)))))
    val byRef = config.filter ?: ::isPlain
    println(byRef(Call(Req(Origin("http", 80)))))
    config.filter = { it.request.origin.port > 1000 }
    val set = config.filter ?: { call -> call.request.origin.port == 80 }
    println(set(Call(Req(Origin("http", 8080)))))
}
