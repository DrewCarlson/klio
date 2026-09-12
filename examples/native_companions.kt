// A class name used as a qualifier. `Config.Default` does not read a field of
// Config: it reads a property of Config's companion, which is an object
// declaration with one instance like any other. A nested class read off its
// outer names a type and holds nothing at all, so the chain that leads to a
// constructor call leaves no value behind.
class Config(val slots: Int) {
    companion object {
        val Default = Config(4)
        val Label = "config"
        fun of(n: Int): Config = Config(n)
    }

    fun describe(): String = Label + ":" + slots
}

class Parser(val text: String) {
    companion object {
        fun of(s: String): Parser = Parser(s)
        fun width(s: String): Int = s.length
    }
}

object Registry {
    val size = 2
}

class Outer {
    class Section(val width: Int) {
        fun grow(): Section = Section(width + 1)
    }
}

fun main() {
    println(Config.Default.slots)
    println(Config.of(9).slots)
    println(Config.Default.describe())
    println(Config.Label)
    println(Registry.size)
    println(Outer.Section(3).grow().width)
    // A function called on a class name is the companion's too.
    println(Parser.of("ab").text)
    println(Parser.width("abcd"))
}
