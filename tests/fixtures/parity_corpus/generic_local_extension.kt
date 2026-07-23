fun main() {
    fun <T> T.localTag(): String = "local"

    println("x".localTag())
}
