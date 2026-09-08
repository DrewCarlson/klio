// A fun interface whose single abstract method is a member EXTENSION on a
// function type. A SAM conversion of it — from a lambda or a bound callable
// reference — is dispatched through the `with` receiver: the call's explicit
// receiver is the abstract method's extension receiver, and the wrapped
// target runs with it bound.

fun interface Accepting {
    fun (Int.() -> String).accept(): String
}

fun label(a: Int.() -> String): String = "label:" + a(7)

fun source(): Int.() -> String = { "n$this" }

fun main() {
    // SAM from a lambda: the extension receiver is the lambda's `this`.
    val fromLambda = Accepting { "lam:" + this(3) }
    with(fromLambda) {
        println(source().accept())
    }

    // SAM from a bound callable reference: the extension receiver becomes
    // the reference's argument.
    val fromRef = Accepting(::label)
    with(fromRef) {
        println(source().accept())
    }
}
