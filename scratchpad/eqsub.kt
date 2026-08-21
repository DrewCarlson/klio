sealed class Provider {
    abstract fun tag(): String
    class Argless(val ser: String) : Provider() {
        override fun tag(): String = ser
        override fun equals(other: Any?): Boolean = other is Argless && other.ser == this.ser
        override fun hashCode(): Int = ser.hashCode()
    }
    class Other : Provider() { override fun tag(): String = "other" }
}

fun main() {
    val a: Provider = Provider.Argless("s")
    val b: Provider = Provider.Argless("s")
    println("eq = " + (a == b))
    println("neq = " + (a != b))
    val map = HashMap<String, Provider>()
    map["k"] = a
    val prev = map["k"]
    println("prev != new = " + (prev != null && prev != b))
}
