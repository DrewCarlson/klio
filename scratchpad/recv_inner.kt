class Scope(val name: String)

fun driver(child: Scope.(block: Scope.() -> Unit) -> Unit) {
    val outer = Scope("outer")
    outer.child {
        println("this = " + name)
    }
}

fun main() {
    driver { fail -> Scope("inner").fail() }
}
