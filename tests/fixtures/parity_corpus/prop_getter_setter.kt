class Doubler {
    var x: Int = 0
        get() = field
        set(value) { field = value * 2 }
}

fun main() {
    val d = Doubler()
    d.x = 5
    println(d.x)
    d.x = 10
    println(d.x)
}
