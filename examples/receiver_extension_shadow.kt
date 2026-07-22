class Scope

fun launch(block: () -> Unit) {
    block()
    println("global")
}

fun Scope.launch(block: () -> Unit) {
    block()
    println("extension")
}

fun withScope(block: Scope.() -> Unit) {
    Scope().block()
}

fun main() {
    withScope {
        launch {}
    }
}
