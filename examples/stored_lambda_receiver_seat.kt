class C {
    override fun toString(): String = "C!"
}

class H1 {
    val plugins = mutableMapOf<String, (C) -> Unit>()
    fun add(name: String) {
        plugins.put(name) { scope -> println("put-variant " + scope) }
    }
}

class H2 {
    val plugins = mutableMapOf<String, (C) -> Unit>()
    fun add(name: String) {
        val block: (C) -> Unit = { scope -> println("typed-local " + scope) }
        plugins[name] = block
    }
}

class H3 {
    val plugins = mutableMapOf<String, (C) -> Unit>()
    fun add(name: String) {
        plugins[name] = { scope -> println("indexed " + scope) }
    }
}

fun main() {
    val c = C()
    val h1 = H1(); h1.add("x"); h1.plugins.values.forEach { c.apply(it) }
    val h2 = H2(); h2.add("x"); h2.plugins.values.forEach { c.apply(it) }
    val h3 = H3(); h3.add("x"); h3.plugins.values.forEach { c.apply(it) }
}
