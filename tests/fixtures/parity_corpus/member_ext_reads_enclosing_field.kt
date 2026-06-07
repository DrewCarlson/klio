// A bare member *property* read inside a member-extension body whose
// `this` is the extension receiver must resolve a field of the
// lexically enclosing class instance, not fail because the extension
// receiver lacks it. Exercises the field-access enclosing-`this`
// fallback (symmetric to the call-side this/enclosing/global probe).
class Vault {
    private val secret: Int = 42
    private val label: String = "vault"

    private val Int.combined: String
        get() = "$label:${secret + this}"

    private fun Int.describe(): String = "$label#${secret - this}"

    fun run(): String {
        val a = 8.combined
        val b = 3.describe()
        return "$a | $b"
    }
}

fun main() {
    println(Vault().run())
}
