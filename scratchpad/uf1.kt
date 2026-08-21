interface Sink<T> { suspend fun push(v: T) }

class ListSink<T>(val out: MutableList<T>) : Sink<T> {
    override suspend fun push(v: T) { out.add(v) }
}

interface Src<T> { suspend fun drain(s: Sink<T>) }

// The `unsafeFlow` shape: a crossinline receiver-lambda invoked with an
// EXPLICIT receiver inside an anonymous object's override.
internal inline fun <T> unsafeSrc(crossinline block: suspend Sink<T>.() -> Unit): Src<T> {
    return object : Src<T> {
        override suspend fun drain(s: Sink<T>) { s.block() }
    }
}

suspend fun <T> Sink<T>.pushAll(src: Src<T>) { src.drain(this) }

fun main() {
    val out = ArrayList<Int>()
    val inner: Src<Int> = unsafeSrc { push(1); push(2) }
    val outer: Src<Int> = unsafeSrc { pushAll(inner); push(3) }
    kotlinx.coroutines.runBlocking { outer.drain(ListSink(out)) }
    println("out = " + out)
}
