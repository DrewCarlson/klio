class Scope(val name: String)

fun driver(child: Scope.(block: Scope.() -> Unit) -> Unit) {
    val outer = Scope("outer")
    outer.child {
        println("block this = " + name)
    }
}

suspend fun sdriver(child: suspend Scope.(block: suspend Scope.() -> Unit) -> Unit) {
    val outer = Scope("outer")
    outer.child {
        println("suspend block this = " + name)
    }
}

fun main() {
    driver { fail -> fail() }
    driver { fail -> this.fail() }
    kotlinx.coroutines.runBlocking {
        sdriver { fail -> fail() }
        sdriver { fail -> this.fail() }
    }
}
