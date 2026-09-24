// A class, an object expression, and an interface can extend a function
// type: instances are called like functions, pass `is` checks against the
// erased FunctionN names, and start as coroutines when the type is suspend.
// A supertype cannot have a receiver, but an instance of `(String) -> String`
// is a `String.() -> String` value and is then called with a receiver.
import kotlin.coroutines.*

class Doubler : (Int) -> Int {
    override fun invoke(p1: Int): Int = p1 * 2
}

class Greeter : (String) -> String {
    override fun invoke(p1: String): String = "hi $p1"
}

interface Producer : suspend () -> Int

class Answer : suspend () -> Int {
    override suspend fun invoke(): Int = 42
}

fun twice(f: (Int) -> Int, x: Int): Int = f(f(x))

fun <T> (suspend () -> T).runNow(): T {
    var result: T? = null
    startCoroutine(object : Continuation<T> {
        override val context = EmptyCoroutineContext
        override fun resumeWith(r: Result<T>) { result = r.getOrThrow() }
    })
    return result!!
}

fun main() {
    val d = Doubler()
    println(d(21))
    println(twice(d, 3))
    println(d is Function1<*, *>)
    println(d is (Int) -> Int)
    println((d as Any) is Function0<*>)

    val g: String.() -> String = Greeter()
    println("bob".g())
    println(g("ann"))

    println(Answer().runNow())
    val p = object : Producer {
        override suspend fun invoke(): Int = 7
    }
    println(p is SuspendFunction0<*>)
    println(p.runNow())

    val plain: Any = { x: Int -> x + 1 }
    val susp: Any = suspend { 1 }
    println(plain is SuspendFunction1<*, *>)
    println(susp is SuspendFunction0<*>)
    println(susp is Function1<*, *>)
}
