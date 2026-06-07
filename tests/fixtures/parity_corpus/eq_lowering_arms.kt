class Always {
    override fun equals(other: Any?): Boolean = (other is Always)
    override fun hashCode(): Int = 1
}

fun main() {
    val a: String? = null
    val b: String = "x"
    println(a == null)
    println(null == a)
    println(b == null)
    println(null == b)
    val n: Any? = null
    println(n == n)
    println(n == b)
    println(b == n)
    val x = Always()
    val nullable: Always? = null
    println(x == nullable)
    println(nullable == x)
}
