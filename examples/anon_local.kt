interface Describable {
    fun describe(): String
}

fun makeDescribable(label: String, count: Int): Describable {
    return object : Describable {
        override fun describe(): String = "$label x$count"
    }
}

fun main() {
    // Anonymous object expression assigned to a val.
    val o = object {
        val msg = "hello"
        fun shout(): String = "$msg!"
    }
    println(o.shout())

    // Anonymous object implementing an interface, returned from a function.
    val d = makeDescribable("widget", 3)
    println(d.describe())

    // Local class declared inside main with closure capture.
    val factor = 10
    class Scaled(val n: Int) {
        fun product(): Int = n * factor
    }
    println(Scaled(4).product())
    println(Scaled(7).product())
}
