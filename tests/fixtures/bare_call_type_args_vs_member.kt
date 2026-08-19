fun <K> thing(): String = "top-level"

fun take(a: String, b: String): String = "$a|$b"

class Holder {
    fun thing() {
        val v = thing<String>()            // initializer position
        println("init: $v")
        println("arg : " + take(thing<String>(), v))   // argument position
    }
}

fun main() = Holder().thing()
