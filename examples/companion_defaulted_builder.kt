// Companion members reached through the class name with a leading defaulted
// parameter skipped: by a trailing lambda (inline and non-inline) and by a
// named argument. Mirrors ktor's `StringValues.build { … }`.

interface Sv {
    companion object {
        inline fun build(flag: Boolean = false, builder: StringBuilder.() -> Unit): String =
            StringBuilder().apply(builder).toString() + "/" + flag
    }
}

class Cv {
    companion object {
        fun make(flag: Boolean = false, builder: StringBuilder.() -> Unit): String =
            StringBuilder().apply(builder).toString() + "/" + flag

        fun tag(flag: Boolean = false, tag: String): String = "$tag/$flag"
    }
}

fun main() {
    println(Sv.build { append("iface") })
    println(Sv.build(true) { append("iface2") })
    println(Cv.make { append("class") })
    println(Cv.tag(tag = "named"))
    println("done")
}
