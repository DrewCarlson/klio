// A member-extension function captured as a value and invoked from inside a
// receiver lambda must bind the lambda's receiver — which a receiver lambda
// holds as a `this`-named *capture*, not a param — as the call's leading
// receiver, rather than shifting the arguments by one. This mirrors ktor's
// HttpRedirect `on(Send) { … handleCall(request, origin, …) }`, where
// `handleCall` is a `Send.Sender` member-extension invoked from the receiver
// lambda; a shifted receiver there fed `origin` a `Boolean` and re-entered the
// send pipeline forever.
interface RawSender {
    fun exec(r: Int): Int
}

class DefaultRaw : RawSender {
    override fun exec(r: Int): Int = r * 2
}

class Sender(private val raw: RawSender) {
    fun proceed(r: Int): Int = raw.exec(r)
}

class Intercepted(
    private val interceptor: RawSender.(Int) -> Int,
    private val next: RawSender,
) : RawSender {
    override fun exec(r: Int): Int = interceptor.invoke(next, r)
}

class Builder {
    private val bump = 1
    var handler: (Sender.(Int) -> Int)? = null

    fun on(h: Sender.(Int) -> Int) {
        handler = h
    }

    // Member-extension on `Sender`: needs both the enclosing `Builder` (for
    // `bump`) and the `Sender` receiver (for `proceed`). Captured and invoked
    // from the `on { … }` receiver lambda below.
    fun Sender.handle(r: Int): Int = proceed(r) + bump
}

fun build(block: Builder.() -> Unit): Sender.(Int) -> Int {
    val b = Builder()
    b.block()
    return b.handler!!
}

fun main() {
    val handler = build { on { r -> handle(r) } }
    val chain: RawSender = Intercepted({ r -> handler.invoke(Sender(this), r) }, DefaultRaw())
    // exec(5) -> handler.invoke(Sender(Default), 5) -> handle(5)
    //   -> proceed(5) = Default.exec(5) = 10 -> + bump(1) = 11
    println(chain.exec(5))
    println(chain.exec(20))
}
