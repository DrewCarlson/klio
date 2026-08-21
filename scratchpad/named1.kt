fun <T, V> apply3(
    ctx: String,
    value: V,
    countOrElement: Any = "default",
    block: (V) -> T
): T {
    println("ctx=$ctx value=$value countOrElement=$countOrElement")
    return block(value)
}

suspend fun <T, V> sapply3(
    ctx: String,
    value: V,
    countOrElement: Any = "default",
    block: suspend (V) -> T
): T {
    println("s ctx=$ctx value=$value countOrElement=$countOrElement")
    return block(value)
}

fun main() {
    println(apply3("c", block = { v: String -> "got:$v" }, value = "V"))
    println(apply3("c", value = "V", block = { v: String -> "got:$v" }))
    kotlinx.coroutines.runBlocking {
        println(sapply3("c", block = { v: String -> "sgot:$v" }, value = "V"))
    }
}
