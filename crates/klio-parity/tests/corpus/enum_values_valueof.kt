enum class Planet { MERCURY, VENUS, EARTH, MARS }

inline fun <reified T : Enum<T>> allNames(): String = enumValues<T>().joinToString(",") { it.name }

fun main() {
    println(enumValues<Planet>().joinToString(",") { it.name })
    println(enumValues<Planet>().size)
    println(enumValueOf<Planet>("EARTH"))
    println(enumValueOf<Planet>("EARTH").ordinal)
    println(allNames<Planet>())
    try {
        enumValueOf<Planet>("PLUTO")
    } catch (e: IllegalArgumentException) {
        println("no such constant")
    }
}
