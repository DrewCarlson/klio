class GenericException<T> : Exception()

fun main() {
    try {
        println("body")
    } catch (e: GenericException<String>) {
        println("caught")
    }
}
