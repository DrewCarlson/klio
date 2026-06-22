var backing: String? = null

val computed: String
    get() = backing ?: "default"

val counter: Int
    get() = backing?.length ?: 0

fun main() {
    println(computed)
    println(counter)
    backing = "set"
    println(computed)
    println(counter)
    backing = null
    println(computed)
}
