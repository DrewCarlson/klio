// A member-extension body resolves a bare property against its dispatch
// receiver using the extension receiver's static type. A runtime subtype's
// unrelated same-named field cannot shadow the enclosing class property.
interface Scope

class RuntimeScope(val state: Int) : Scope

class Owner(val state: Int) {
    fun Scope.readState(): Int = listOf(Unit).map { state }.first()

    fun readFrom(scope: Scope): Int = scope.readState()
}

fun main() {
    println(Owner(7).readFrom(RuntimeScope(99)))
}
