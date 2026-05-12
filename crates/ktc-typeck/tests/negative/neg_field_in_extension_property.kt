val String.shouted: String
    get() = field + "!"

fun main() {
    println("hi".shouted)
}
