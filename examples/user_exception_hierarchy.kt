// User-defined exception classes dispatched through a built-in catch type.
// Spec §16.1: a catch is applicable when the thrown value's runtime type is
// a subtype of the bound exception parameter — walks both the user-declared
// supertype chain and the built-in Throwable hierarchy.

open class AppError(msg: String) : RuntimeException(msg)
class NotFound(val key: String) : AppError("missing $key")
class Forbidden(val who: String) : AppError("$who forbidden")

fun lookup(key: String) {
    if (key.isEmpty()) throw IllegalArgumentException("empty key")
    if (key == "secret") throw Forbidden("anonymous")
    if (key != "ok") throw NotFound(key)
    println("found $key")
}

fun report(key: String) {
    try {
        lookup(key)
    } catch (e: NotFound) {
        println("[NotFound] ${e.key}")
    } catch (e: AppError) {
        println("[AppError] $key")
    } catch (e: RuntimeException) {
        println("[RuntimeException] $key")
    }
}

fun main() {
    report("ok")
    report("secret")
    report("missing-key")
    report("")
}
