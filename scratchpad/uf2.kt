import kotlinx.coroutines.runBlocking

interface Sink<T> { suspend fun push(v: T) }
class ListSink<T>(val out: MutableList<T>) : Sink<T> { override suspend fun push(v: T) { out.add(v) } }
interface Src<T> { suspend fun drain(s: Sink<T>) }

internal inline fun <T> unsafeSrc(crossinline block: suspend Sink<T>.() -> Unit): Src<T> =
    object : Src<T> {
        override suspend fun drain(s: Sink<T>) { s.block() }
    }

suspend inline fun <T> Src<T>.each(crossinline action: suspend (T) -> Unit) {
    drain(object : Sink<T> { override suspend fun push(v: T) { action(v) } })
}

suspend fun <T> Sink<T>.pushAll(src: Src<T>) { src.drain(this) }

// The `flattenConcat` shape: a bare call two lambda levels out.
fun <T> Src<Src<T>>.flatten(): Src<T> = unsafeSrc {
    each { value -> pushAll(value) }
}

fun main() {
    val nested: Src<Src<Int>> = unsafeSrc {
        push(unsafeSrc { push(1); push(2) })
        push(unsafeSrc { push(3) })
    }
    val out = ArrayList<Int>()
    runBlocking { nested.flatten().drain(ListSink(out)) }
    println("out = " + out)
}
