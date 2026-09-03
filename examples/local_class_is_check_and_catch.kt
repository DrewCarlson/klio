// A function-local class keeps its identity at runtime under its bare name:
// a reified `filterIsInstance<Local>()`, a plain `is` check, and a `catch`
// clause naming a local exception class all match instances of that class,
// even when the lowering spells the class by its function-scoped alias.
open class Super(val tag: String)

fun sortLocals(): List<String> {
    open class Base(val n: Int)
    class Sub(n: Int) : Base(n)
    val items: List<Any> = listOf(Base(1), Sub(2), "x", Base(3), 4, Sub(5))
    val bases = items.filterIsInstance<Base>().map { it.n }
    val subs = items.filterIsInstance<Sub>().map { it.n }
    val plain = items.count { it is Base }
    return listOf("bases=$bases", "subs=$subs", "is=$plain")
}

fun catchLocal(): String {
    class MyException(val code: Int) : Exception("local failure")
    return try {
        throw MyException(7)
    } catch (e: MyException) {
        "caught ${e.message} code=${e.code}"
    }
}

fun main() {
    for (line in sortLocals()) println(line)
    println(catchLocal())
}
