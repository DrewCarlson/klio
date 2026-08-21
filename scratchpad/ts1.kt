class Box(val n: Int) { override fun toString(): String = "Box($n)" }
fun main() {
    val b = Box(1)
    println("direct  = " + b)
    println("interp  = $b")
    println("tostr   = " + b.toString())
    println("list    = " + listOf(b))
    println("listT   = " + listOf(b).toString())
    println("joined  = " + listOf(b).joinToString())
    println("set     = " + setOf(b))
    println("map     = " + mapOf(1 to b))
    println("pair    = " + (1 to b))
    println("array   = " + arrayOf(b).contentToString())
}
