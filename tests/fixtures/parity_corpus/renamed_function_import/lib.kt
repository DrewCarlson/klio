package renamed.function.imports.lib

fun String.choose(other: String): String = "extension:$this:$other"

fun choose(first: String, second: String, third: String): String =
    "plain:$first:$second:$third"

inline fun choose(
    first: String,
    second: String,
    third: String,
    fourth: String,
): String = "inline:$first:$second:$third:$fourth"

fun merge(vararg values: String): String = values.joinToString("+")

class Pipe(val value: Int)

inline fun Pipe.rewrite(block: (Int) -> Int): Int = block(value)
