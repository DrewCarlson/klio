// Context parameters (Kotlin 2.4): a declaration is made available implicitly
// through the enclosing scope rather than passed at every call site. A
// `context(name: Type)` clause on a function or property brings the value into
// scope by name; the stdlib `context(value) { ... }` establishes it, and
// `contextOf<T>()` reads the nearest in-scope value of a type.

interface Logger {
    fun log(m: String)
}

class ConsoleLogger : Logger {
    override fun log(m: String) = println("[log] $m")
}

// A named context parameter is in scope by name in the body.
context(logger: Logger)
fun record(event: String) = logger.log(event)

// One contextual function forwards to another; the context flows implicitly.
context(_: Logger)
fun runJob(name: String) {
    record("start $name")
    record("done $name")
}

// A contextual property has no backing field; both are unnecessary here.
context(logger: Logger)
val banner: String
    get() = "== ${contextOf<Logger>().let { "ready" }} =="

// A generic context parameter resolves against the call-site type argument.
context(ctx: T)
fun <T> current(): T = ctx

// A member function resolves its context from the dispatch receiver.
class Service {
    fun describe() = "service#$id"
    val id = 7
    context(s: Service)
    fun report() = println("report for ${s.describe()}")
    fun run() = report()
}

fun main() {
    val logger = ConsoleLogger()
    context(logger) {
        println(banner)
        record("hello")
        runJob("build")
    }

    // `contextOf<T>()` reads the nearest value of the requested type.
    context("scope-A") {
        context(42) {
            println("string=${contextOf<String>()} int=${contextOf<Int>()}")
        }
    }

    // A generic contextual accessor with an explicit type argument.
    context("answer") {
        println("current=${current<String>()}")
    }

    // The dispatch receiver satisfies a member's context parameter.
    Service().run()
}
