// A lambda parameter whose type is only INFERRED from the function it is
// passed to keeps every fact that type carries. When that type is an
// extension-function type (`Scope.() -> Unit`), a bare call to the parameter
// invokes it with the enclosing receiver, exactly as an annotated parameter
// would — including across suspend boundaries, where the receiver decides
// which coroutine scope a builder attaches to.
//
// Run with: klio run examples/receiver_lambda_param_inferred.kt

class Scope(val name: String) {
    fun describe(): String = "scope=$name"
}

fun drive(outer: String, run: Scope.(body: Scope.() -> String) -> String): String =
    Scope(outer).run { describe() }

fun driveTwoArgs(outer: String, run: Scope.(body: Scope.(Int) -> String) -> String): String =
    Scope(outer).run { n -> "$name#$n" }

fun main() {
    // The bare call forwards the enclosing receiver.
    println(drive("outer") { body -> body() })
    // An explicit receiver still wins where one is written.
    println(drive("outer") { body -> Scope("inner").body() })
    // `this.` is the same call as the bare one.
    println(drive("outer") { body -> this.body() })
    // Value parameters ride alongside the receiver.
    println(driveTwoArgs("outer") { body -> body(7) })

    // Nested one level: the inner bare call takes the inner receiver.
    println(drive("a") { body -> drive("b") { inner -> inner() } + "|" + body() })
}
