// Flow.combine: the latest values of two flows combined through a transform.
// combineInternal invokes its receiver-typed `transform` param from inside the
// flowScope coroutine; the call must bind this@combineInternal (the downstream
// FlowCollector) as the lambda receiver, not the coroutine that resumed it.
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val numbers = flowOf(1, 2, 3)
    val letters = flowOf("x", "y", "z")
    val combined = combine(numbers, letters) { n, s -> "$n-$s" }.toList()
    println("combine=" + combined)
    val member = numbers.combine(letters) { n, s -> "$n$s" }.toList()
    println("member=" + member)
}
