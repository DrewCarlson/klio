class Builder(var host: String) {
    fun buildString(): String {
        return "member:" + authority
    }
}

val Builder.authority: String
    get() = buildString {
        append("auth(")
        append(host)
        append(")")
    }

fun main() {
    val b = Builder("example.com")
    println(b.buildString())
    println(b.authority)
}
