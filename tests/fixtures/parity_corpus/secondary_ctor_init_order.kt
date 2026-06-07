class Logger(val tag: String) {
    init {
        println("init: $tag")
    }

    constructor(tag: String, level: Int) : this(tag) {
        println("secondary: $tag level=$level")
    }
}

fun main() {
    println("--- one-arg ---")
    Logger("alpha")
    println("--- two-arg ---")
    Logger("beta", 3)
}
