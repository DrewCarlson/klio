fun <T> scope(value: T, block: T.() -> String): String = value.block()

fun String.pick(): String = "String"

fun Any.pick(): String = "Any"

fun String.which(): String = "String"

fun Any?.which(): String = "nullable"

fun main() {
    println(scope<Any>("x") { pick() })
    println(scope<String?>(null) { which() })
}
