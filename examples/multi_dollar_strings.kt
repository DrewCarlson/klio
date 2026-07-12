// Multi-dollar string interpolation (Kotlin 2.2): N leading dollars set the
// template marker length; shorter dollar runs are literal text. Raw strings
// close on the LAST three quotes of a quote run, so extra quotes belong to
// the content.

fun main() {
    val default = 5
    val z = 9
    println($$"runTest$default")
    println($$"a$${1 + 1}b")
    println($$"x$$default!")
    println($$$"y$$$default $$z")
    println(""""v"quoted"v"""")
}
