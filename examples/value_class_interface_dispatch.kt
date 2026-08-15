interface Painter {
    fun paint(): String
}

@JvmInline
value class Solid(val rgb: Long) : Painter {
    override fun paint(): String = "solid:" + rgb
}

@JvmInline
value class Gradient(val stops: Int) : Painter {
    override fun paint(): String = "gradient:" + stops
}

fun main() {
    val ps: List<Painter> = listOf(Solid(7), Gradient(3))
    for (p in ps) {
        println(p.paint())
        println(p::class.simpleName)
        println(p.toString().length > 0)
    }
    val any: Any = Solid(11)
    println((any as Painter).paint())
    println(any.hashCode() == Solid(11).hashCode())
    println(Solid(5) == Solid(5))
}
