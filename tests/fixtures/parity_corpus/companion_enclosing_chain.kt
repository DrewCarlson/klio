class Outer {
    companion object {
        const val NAME = "outer"
    }
    class Inner {
        companion object {
            fun describe(): String = "$NAME/inner"
        }
    }
}

fun main() {
    println(Outer.Inner.describe())
}
