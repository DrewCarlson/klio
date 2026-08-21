class Bag { var name: String? = null }

class Fmt(val label: String) {
    fun write(block: Bag.() -> Unit): String { val b = Bag(); b.block(); return b.name ?: "<unset>" }
    fun read(input: String): Bag { val b = Bag(); b.name = input; return b }
}

fun main() {
    val f = Fmt("x")
    println("write -> " + f.write { name = "Berlin" })
    println("read  -> " + f.read("NY").name)
    println("read2 -> " + f.read("LA").name)
}
