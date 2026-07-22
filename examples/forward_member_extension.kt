class ForwardScope(val value: Int)

fun callInScope(
    scope: ForwardScope,
    block: ForwardScope.() -> Int,
): Int = scope.block()

class ForwardHost {
    fun result(): Int = callInScope(ForwardScope(41)) { later() }

    private fun ForwardScope.later(): Int = value + 1
}

fun main() {
    println("result=${ForwardHost().result()}")
}
