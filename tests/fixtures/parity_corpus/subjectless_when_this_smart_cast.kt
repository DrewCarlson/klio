interface Source

interface DropSource : Source {
    fun drop(count: Int): String
}

class FastSource : DropSource {
    override fun drop(count: Int): String = "member:$count"
}

fun Source.drop(count: Int): String = when {
    count == 0 -> "zero"
    this is DropSource -> this.drop(count)
    else -> "fallback"
}

fun main() {
    val source: Source = FastSource()
    println(source.drop(2))
    println(source.drop(0))
}
