// Catch matching over a user-defined exception hierarchy, compiled to C. The
// emitter numbers the program's throwable types in preorder, so every subtype
// of a type falls in one contiguous interval: a thrown value carries its own
// number and a handler compares it against two integers. A `catch` therefore
// sees a subtype however deep it sits, at the same cost as catching the exact
// type.
open class AppError(msg: String) : Exception(msg)

open class NotFound(msg: String) : AppError(msg)

class RowNotFound(msg: String) : NotFound(msg)

class Denied(msg: String) : AppError(msg)

fun lookup(k: Int): Int {
    if (k == 1) throw RowNotFound("no such row")
    if (k == 2) throw Denied("not allowed")
    if (k == 3) throw IllegalArgumentException("bad key")
    return k
}

// A handler for the base type catches every type beneath it.
fun classify(k: Int): String {
    try {
        lookup(k)
        return "ok"
    } catch (e: NotFound) {
        return "not found"
    } catch (e: AppError) {
        return "app error"
    } catch (e: RuntimeException) {
        return "runtime"
    }
}

fun main() {
    var i = 0
    while (i < 5) {
        println(classify(i))
        i = i + 1
    }

    // The exact type still matches, and a sibling branch does not.
    try {
        throw Denied("direct")
    } catch (e: NotFound) {
        println("wrong branch")
    } catch (e: Denied) {
        println("denied")
    }

    // `Throwable` roots the hierarchy, so it spans every type in it.
    try {
        throw RowNotFound("deep")
    } catch (e: Throwable) {
        println("root caught")
    }
}
