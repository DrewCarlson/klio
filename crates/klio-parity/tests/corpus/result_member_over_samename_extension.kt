// A bare call inside `Result<T>.xxx()` must bind to the
// `kotlin.Result` member/intrinsic, not to a same-named extension
// declared for an unrelated user class (upstream kotlinx-coroutines'
// `Result<T>.toState() = getOrElse { … }` was resolving to
// `ChannelResult.getOrElse`, which reads a `holder` field a
// `kotlin.Result` does not have).
class Bag(val holder: Any?)

fun Bag.getOrElse(onFailure: (Throwable) -> String): String =
    (holder as? String) ?: onFailure(RuntimeException("x"))

fun <T> Result<T>.toState(): Any? = getOrElse { "FAIL:" + it.message }

fun main() {
    println(runCatching { 42 }.toState())
    println(runCatching<Int> { throw RuntimeException("boom") }.toState())
    // The user-class extension still resolves on its own receiver.
    println(Bag("ok").getOrElse { "none" })
    println(Bag(7).getOrElse { "none" })
}
