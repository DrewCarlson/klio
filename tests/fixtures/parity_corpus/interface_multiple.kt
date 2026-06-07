interface Walker {
    fun walk(): String = "walking"
}

interface Swimmer {
    fun swim(): String = "swimming"
}

class Duck : Walker, Swimmer

fun main() {
    val d = Duck()
    println(d.walk())
    println(d.swim())
}
