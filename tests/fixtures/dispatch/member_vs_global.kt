fun gadget(): Int = 7

class Unrelated {
    fun gadget(): Int = 100
}

class Caller {
    fun run(): Int = gadget()
}

fun main() {
    println(Caller().run())
}
