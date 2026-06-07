// A Kotlin `object` initializes lazily on first access, not at program
// start. `Unused` is never accessed, so its throwing initializer never
// runs and the program completes normally.
object Unused {
    val boom: String = throw RuntimeException("should not run")
}

object Used {
    val greeting: String = "hello"
}

fun main() {
    println(Used.greeting)
    println("done")
}
