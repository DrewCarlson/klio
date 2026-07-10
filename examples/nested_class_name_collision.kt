// Two nested classes sharing a simple name (`Builder`) under different
// outers keep distinct identities: each resolves its own enclosing
// companion (`Default`) — the HexFormat Bytes/Number Builder shape.

class Outer {
    class Section(val width: Int) {
        companion object {
            val Default = Section(11)
        }

        class Builder {
            var width: Int = Default.width
            fun build(): Section = Section(width)
        }
    }

    class Number(val prefix: String) {
        companion object {
            val Default = Number("np")
        }

        class Builder {
            var prefix: String = Default.prefix
            fun build(): Number = Number(prefix)
        }
    }

    companion object {
        val Default = Outer()
    }
}

fun main() {
    println("sec=" + Outer.Section.Builder().build().width)
    println("num=" + Outer.Number.Builder().build().prefix)
}
