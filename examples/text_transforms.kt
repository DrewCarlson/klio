fun main() {
    // chunked with a transform: fold each window as it is produced.
    val nums = (1..10).toList()
    println(nums.chunked(3) { it.sum() })
    println(nums.chunked(4) { it.first() to it.last() })

    // Regex.replace with a transform lambda over each match.
    val masked = "call 555-1234 or 555-9876".replace(Regex("\\d{3}-\\d{4}")) { m ->
        "*".repeat(m.value.length)
    }
    println(masked)

    // Group references in a replacement template.
    println("2024-06-01".replace(Regex("(\\d+)-(\\d+)-(\\d+)"), "$3.$2.$1"))

    // replaceFirst only rewrites the first match.
    println("one two two two".replaceFirst(Regex("two"), "2"))

    // Capitalize each word via a transform.
    val title = "the quick brown fox".replace(Regex("\\b\\w")) { it.value.uppercase() }
    println(title)
}
