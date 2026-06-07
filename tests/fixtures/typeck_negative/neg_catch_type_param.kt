fun <E : Exception> trapped() {
    try {
        println("body")
    } catch (e: E) {
        println("caught")
    }
}

fun main() {
    trapped<Exception>()
}
