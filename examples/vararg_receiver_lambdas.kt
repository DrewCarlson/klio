// Receiver lambdas passed to a `vararg` parameter. Each literal is a
// `Sink.() -> Unit`, so inside it `emit(...)` resolves against the Sink the
// call supplies — not against whatever `this` the enclosing scope has.
//
// A receiver lambda declares no value parameter, so invoking one supplies the
// receiver as its single argument. That holds however the element is reached:
// through a for-loop over the vararg, by index, or via forEach.
//
// Run with: klio run examples/vararg_receiver_lambdas.kt

class Sink {
    val out = StringBuilder()
    fun emit(s: String) {
        out.append(s)
    }
}

fun viaLoop(vararg blocks: Sink.() -> Unit): String {
    val s = Sink()
    for (b in blocks) b(s)
    return s.out.toString()
}

fun viaIndex(vararg blocks: Sink.() -> Unit): String {
    val s = Sink()
    var i = 0
    while (i < blocks.size) {
        blocks[i](s)
        i = i + 1
    }
    return s.out.toString()
}

fun viaForEach(vararg blocks: Sink.() -> Unit): String {
    val s = Sink()
    blocks.forEach { it(s) }
    return s.out.toString()
}

// A vararg followed by a further receiver-lambda parameter: the trailing one
// keeps its own position while every earlier literal belongs to the vararg.
fun withPrimary(vararg others: Sink.() -> Unit, primary: Sink.() -> Unit): String {
    val s = Sink()
    for (b in others) b(s)
    primary(s)
    return s.out.toString()
}

val declared: Sink.() -> Unit = { emit("D") }

fun main() {
    println("none          = '" + viaLoop() + "'")
    println("one literal   = " + viaLoop({ emit("A") }))
    println("two literals  = " + viaLoop({ emit("A") }, { emit("B") }))
    println("three         = " + viaLoop({ emit("A") }, { emit("B") }, { emit("C") }))
    println("declared vals = " + viaLoop(declared, declared))
    println("mixed         = " + viaLoop(declared, { emit("A") }))

    println("by index      = " + viaIndex({ emit("A") }, { emit("B") }))
    println("by forEach    = " + viaForEach({ emit("A") }, { emit("B") }))

    println("with primary  = " + withPrimary({ emit("A") }, { emit("B") }, primary = { emit("M") }))
    println("primary only  = " + withPrimary(primary = { emit("M") }))
}
