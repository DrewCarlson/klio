// Dotted package-head resolution INSIDE coroutine/flow builder lambdas: a
// fully-qualified `kotlin.math.*` head must flatten to a global FQN load the
// same way whether it appears at top level or lexically inside a `flow { }`,
// `launch { }`, or `coroutineScope { }` receiver lambda — pack code is
// consumed almost entirely through such builders, so this pins that the head
// resolves identically across SourcePacks and CompiledPacks.
//> e2
//> e4
//> e6
//> s=12
//> a=7
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    flow {
        emit(1)
        emit(2)
        emit(3)
    }.collect { n ->
        println("e${kotlin.math.max(n * 2, 0)}")
    }
    val s = coroutineScope {
        val a = async { kotlin.math.min(12, 99) }
        a.await()
    }
    println("s=$s")
    launch {
        val v = kotlin.math.abs(-7)
        println("a=$v")
    }.join()
}
