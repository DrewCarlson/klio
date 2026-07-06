var watched: Int = 0
    set(value) {
        println("set to $value")
        field = value
    }

var scaled: Int = 10
    get() = field + 100
    set(v) { field = v * 2 }

var backed: Int = 1
    get() = field + 100

val computed: Int
    get() = 42

fun main() {
    watched = 5
    println(watched)
    watched += 2
    println(watched)
    println(scaled)
    scaled = 3
    println(scaled)
    println(backed)
    backed = 7
    println(backed)
    println(computed)
}
