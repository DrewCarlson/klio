fun applyToIterable(
    value: Iterable<String>,
    operation: (Iterable<String>) -> List<String>,
): List<String> = operation(value)

fun main() {
    val elementResult = applyToIterable(setOf("foo", "bar")) {
        it + "zoo" + "g"
    }
    println(elementResult)
    println(elementResult == listOf("foo", "bar", "zoo", "g"))

    val collectionResult = applyToIterable(setOf("foo", "bar")) {
        it + listOf("zoo", "g")
    }
    println(collectionResult)
    println(collectionResult == listOf("foo", "bar", "zoo", "g"))
}
