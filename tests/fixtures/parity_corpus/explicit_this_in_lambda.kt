// `this` is a valid primary expression inside a lambda-with-receiver.
fun main() {
    val r = "hi".run { this.uppercase() }
    println(r)
}
