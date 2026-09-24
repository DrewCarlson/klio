sealed interface Status {
    data object Loading : Status
    data class Error(val code: Int, val critical: Boolean) : Status
    data class Ok(val items: List<String>) : Status
}

fun render(status: Status): String = when (status) {
    Status.Loading -> "loading"
    is Status.Ok if status.items.isEmpty() -> "no data"
    is Status.Ok -> status.items.joinToString()
    is Status.Error if status.critical -> "critical error ${status.code}"
    is Status.Error -> "error ${status.code}"
}

fun classify(x: Any?): String = when (x) {
    is String if x.length > 3 -> "long string"
    is String -> "short string"
    is Int if x < 0 -> "negative"
    null -> "nothing"
    else if x is Int -> "int"
    else -> "other"
}

fun main() {
    println(render(Status.Loading))
    println(render(Status.Ok(emptyList())))
    println(render(Status.Ok(listOf("a", "b"))))
    println(render(Status.Error(500, true)))
    println(render(Status.Error(404, false)))
    for (x in listOf<Any?>("kotlin", "kt", -3, 7, null, 2.5)) println(classify(x))
}
