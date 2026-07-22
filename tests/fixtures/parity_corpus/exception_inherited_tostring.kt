open class AppFailure(message: String) : RuntimeException(message)

class SpecificFailure(message: String) : AppFailure(message)

class DecoratedFailure(message: String) : Exception(message) {
    override fun toString(): String = "decorated ${super.toString()}"
}

fun main() {
    println(SpecificFailure("bad"))
    println(DecoratedFailure("worse"))
}
