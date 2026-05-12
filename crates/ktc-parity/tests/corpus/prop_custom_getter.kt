class Person(val first: String, val last: String) {
    val full: String
        get() = "$first $last"
}

fun main() {
    val p = Person("Ada", "Lovelace")
    println(p.full)
    println(p.first)
    println(p.last)
}
