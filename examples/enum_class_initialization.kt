// An enum class initializes on its first active use, the way the JVM
// initializes a class: every entry constructs in declaration order, then
// the companion object initializes as part of the same initialization.
// A nested object of the enum is a class of its own and does not trigger
// it; an entry read, `valueOf()`, `values()`, `entries`, a companion
// member and `enumValueOf<T>()` do.
var log = ""

enum class Color(val code: Int) {
    RED(1), GREEN(2);

    init {
        log += "Color.$name;"
    }

    companion object {
        init {
            log += "Color.companion(${entries.size});"
        }

        val count = 2
        fun first() = RED
    }

    object Names {
        init {
            log += "Color.Names;"
        }

        fun of(c: Color) = c.name.lowercase()
    }
}

enum class Level {
    LOW, HIGH;

    init {
        log += "Level.$name;"
    }

    companion object {
        init {
            log += "Level.companion;"
        }
    }
}

enum class Mode {
    ON, OFF;

    init {
        log += "Mode.$name;"
    }

    companion object {
        init {
            log += "Mode.companion;"
        }

        fun describe() = "modes=${entries.size}"
    }
}

enum class Unit2 {
    METER, SECOND;

    init {
        log += "Unit2.$name;"
    }
}

fun main() {
    println("before any use: [$log]")
    val names = Color.Names
    println("after Color.Names: [$log]")
    val c = Color.GREEN
    println("after Color.GREEN: [$log] code=${c.code}")
    println("Color.first()=${Color.first()} count=${Color.count} names.of(c)=${names.of(c)}")
    println("no further initialization: [$log]")

    log = ""
    try {
        Level.valueOf("MEDIUM")
    } catch (e: IllegalArgumentException) {
        log += "caught;"
    }
    println("after Level.valueOf: [$log]")

    log = ""
    println(Mode.describe())
    println("after Mode.describe(): [$log]")

    log = ""
    println(enumValueOf<Unit2>("SECOND").ordinal)
    println("after enumValueOf<Unit2>: [$log]")
}
