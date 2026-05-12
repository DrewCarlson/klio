// A companion object inside an enum class can resolve `entries` and the
// enum's own entries by bare name, just like kotlinc-native.
enum class Level {
    LOW, MID, HIGH;

    companion object {
        fun fromName(s: String): Level = entries.first { it.name == s }
        fun all(): List<Level> = entries
    }
}

fun main() {
    println(Level.fromName("LOW"))
    println(Level.fromName("MID"))
    println(Level.fromName("HIGH"))
    for (e in Level.all()) {
        println(e)
    }
}
