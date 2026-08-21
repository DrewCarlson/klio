package xf

interface Sink { fun emit(v: Int) }
interface Src { fun drain(s: Sink) }

internal inline fun mkSrc(crossinline block: Sink.() -> Unit): Src = object : Src {
    override fun drain(s: Sink) { s.block() }
}
