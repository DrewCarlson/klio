// Class delegation serving a member invoked with named arguments: the
// forward to the delegate keeps the names, so parameters bind by name.

interface Sink {
    fun emit(tag: String, value: Int = 0, scale: Float = 1f): String
}

class RealSink : Sink {
    override fun emit(tag: String, value: Int, scale: Float): String =
        "$tag:$value@$scale"
}

class Wrapper(private val inner: RealSink) : Sink by inner

fun main() {
    val w: Sink = Wrapper(RealSink())
    println(w.emit("a", value = 7))
    println(w.emit(tag = "b", scale = 2.5f))
}
