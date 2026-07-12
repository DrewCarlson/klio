// The `coroutineContext` intrinsic inside a class member suspend function,
// when the coroutine was launched with `startCoroutine(Continuation(ctx) {})`:
// the stdlib `Continuation` factory completion declares only `context`, and
// the intrinsic must resolve to the current continuation's context rather
// than missing the member (or diverging between member and top-level reads).

import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.coroutines.coroutineContext

class Pipe {
    suspend fun execute() {
        println("ctx member: " + coroutineContext)
    }
}

suspend fun topExecute() {
    println("ctx top: " + coroutineContext)
}

fun main() {
    val p = Pipe()
    val body = suspend {
        topExecute()
        p.execute()
    }
    val completion: Continuation<Unit> = Continuation(EmptyCoroutineContext) {
        println("completed: " + it)
    }
    body.startCoroutine(completion)
}
