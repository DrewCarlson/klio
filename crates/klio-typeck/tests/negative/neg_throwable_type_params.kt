class MyEx<T>(message: String) : RuntimeException(message)

fun main() {
    throw MyEx<Int>("boom")
}
