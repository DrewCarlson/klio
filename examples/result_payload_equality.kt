// Result is a value class, but equality of its payload still dispatches the
// payload's Kotlin equals implementation.

class ResultToken(val value: Int) {
    override fun equals(other: Any?): Boolean =
        other is ResultToken && value == other.value

    override fun hashCode(): Int = value
}

@JvmInline
value class WrappedResultToken(val token: ResultToken)

fun main() {
    val first = Result.success(ResultToken(7))
    val same = Result.success(ResultToken(7))
    val different = Result.success(ResultToken(8))
    val wrapped = WrappedResultToken(ResultToken(7))
    println("same=${first == same}")
    println("different=${first == different}")
    println("wrappedSame=${wrapped == WrappedResultToken(ResultToken(7))}")
    println("wrappedDifferent=${wrapped == WrappedResultToken(ResultToken(8))}")
}
