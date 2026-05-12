// M12: sealed classes + `when` expression + smart casts on `is`.

sealed class Json
class JsonNum(val value: Int): Json()
class JsonStr(val value: String): Json()
class JsonBool(val value: Boolean): Json()
class JsonArr(val items: List<Json>): Json()

fun render(node: Json): String = when (node) {
    is JsonNum -> node.value.toString()
    is JsonStr -> "\"${node.value}\""
    is JsonBool -> if (node.value) "true" else "false"
    is JsonArr -> {
        val parts = node.items.map { render(it) }
        "[${parts.joinToString(",")}]"
    }
    else -> "null"
}

fun bucket(n: Int): String = when (n) {
    0 -> "zero"
    1, 2, 3 -> "small"
    in 4..10 -> "mid"
    !in 0..100 -> "out-of-range"
    else -> "big"
}

fun main() {
    val tree: Json = JsonArr(listOf(JsonNum(1), JsonStr("two"), JsonBool(true), JsonArr(listOf(JsonNum(3)))))
    println(render(tree))

    for (n in listOf(0, 2, 7, 42, -5)) {
        println("$n -> ${bucket(n)}")
    }

    val anyValue: Any = "kotlin"
    println(anyValue is String)
    println(anyValue !is Int)
}
