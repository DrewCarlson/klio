fun <T> List<T>.tag(): String = "top"

class ShadowOwner(private val match: String) {
    fun String.isBlank(): Boolean = this == match

    fun <T> List<T>.tag(): String = "member:$match"

    fun direct(value: String): Boolean = value.isBlank()

    fun nested(value: String): Boolean = run {
        value.isBlank()
    }

    fun generic(): String = listOf("x").tag()
}

fun nestedWith(owner: ShadowOwner): String = with(owner) {
    with(StringBuilder()) {
        listOf("x").tag()
    }
}

fun main() {
    val owner = ShadowOwner("x")
    println(owner.direct(""))
    println(owner.nested("x"))
    println(with(owner) { "".isBlank() })
    println(owner.generic())
    println(with(owner) { listOf(1).tag() })
    println(listOf("x").tag())
    println(nestedWith(owner))
}
