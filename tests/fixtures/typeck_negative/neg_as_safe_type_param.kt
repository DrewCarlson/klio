fun <T> tryCast(x: Any): T? {
    return x as? T
}

fun main() {
    val r: Int? = tryCast<Int>("oops")
    println(r)
}
