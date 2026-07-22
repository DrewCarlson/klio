import kotlin.coroutines.ContinuationInterceptor

fun main() {
    val holder = object {
        val key = ContinuationInterceptor
    }
    println("same=${holder.key === ContinuationInterceptor}")
}
