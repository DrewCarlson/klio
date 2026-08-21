class Scope(val name: String)

fun driver(tag: String, child: Scope.(block: Scope.() -> Unit) -> Unit) {
    val outer = Scope("outer")
    outer.child {
        println("$tag -> " + name)
    }
}

fun main() {
    driver("bare") { fail -> fail() }
    driver("this.") { fail -> this.fail() }
    driver("inline-body") { fail -> Scope("inner").fail() }
}
