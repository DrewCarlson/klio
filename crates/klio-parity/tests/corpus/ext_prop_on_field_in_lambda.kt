// An extension property read on an implicit-receiver member field,
// from inside a lambda body, must resolve as `this.<field>` then the
// extension property — not be mis-flattened to a dotted global FQN
// (only a genuine package root flattens inside a lambda). Mirrors
// upstream `JobSupport.run { … resumeMode.isCancellableMode … }`.

val Int.isCancellableMode: Boolean get() = this == 1 || this == 2

class Task(var mode: Int) {
    private fun runIn(block: () -> String): String = block()
    fun describe(): String = runIn {
        if (mode.isCancellableMode) "cancellable:$mode" else "plain:$mode"
    }
}

fun main() {
    println(Task(1).describe())
    println(Task(2).describe())
    println(Task(0).describe())
    println(5.isCancellableMode)
    println(1.isCancellableMode)
}
