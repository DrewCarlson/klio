// `apply` binds the receiver as `this`. Bare names inside the block
// resolve via implicit-this. Returns the receiver.
fun main() {
    val r = "hi".apply { println("len=$length") }
    println(r)
}
