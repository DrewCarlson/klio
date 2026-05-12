open class Vault(val owner: String) {
    private val secret: Int = 42
    protected val signature: String = "vault-of-${owner}"
    internal val tag: String = "internal-tag"
    val label: String = "public-label"

    fun describePrivate(): Int = secret
}

class StrongVault(o: String) : Vault(o) {
    fun reveal(): String = signature
}

fun main() {
    val v = Vault("alice")
    println(v.label)
    println(v.tag)
    println(v.describePrivate())
    val s = StrongVault("bob")
    println(s.reveal())
}
