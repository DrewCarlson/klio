// A call written with explicit type arguments cannot be answered by a
// same-named member that declares no type parameters, so that member does not
// shadow the top-level generic function.
//
// This shape is ordinary in test suites: a test method is named after the
// function it exercises. androidx.collection's own suite declares
// `@Test fun emptyObjectIntMap()` and calls the imported
// `fun <K> emptyObjectIntMap()` inside it. Binding the method to itself
// recurses forever.
//
// Run with: klio run examples/type_args_vs_member_name.kt

fun <K> makeTag(): String = "top-level"

fun join(a: String, b: String): String = "$a|$b"

class Holder {
    // Same name as the top-level function, and no type parameters of its own.
    fun makeTag() {
        // Initializer position.
        val first = makeTag<String>()
        // Argument position: the same call, and it must resolve identically.
        println(join(first, makeTag<Int>()))
    }

    // A member that DOES take a type parameter still wins its own call.
    fun <T> tagged(): String = "member"

    fun viaMember() {
        println("member wins: " + tagged<String>())
    }
}

fun main() {
    Holder().makeTag()
    Holder().viaMember()
}
