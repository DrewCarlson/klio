class Builder {
    internal val elementAnnotations: MutableList<List<String>> = ArrayList()
    fun element(annotations: List<String> = emptyList()) {
        elementAnnotations += annotations
    }
    fun elementThis(annotations: List<String> = emptyList()) {
        this.elementAnnotations += annotations
    }
}

fun main() {
    val b = Builder()
    b.element()
    b.element(listOf("x"))
    println("bare = " + b.elementAnnotations + " size=" + b.elementAnnotations.size)
    val c = Builder()
    c.elementThis()
    println("this = " + c.elementAnnotations + " size=" + c.elementAnnotations.size)
}
