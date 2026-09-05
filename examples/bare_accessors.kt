// A property may declare an accessor by its keyword alone: `get` on its
// own line keeps the default getter, `private set` after a `;` on the
// declaration line narrows the setter's visibility, and a `lateinit var`
// may carry `set` the same way. The accessors behave exactly as the
// defaults do.
class Account {
    val id = 7
        get
    var balance: Int = 10; private set
    var owner: String = "nobody"
        private set

    fun deposit(n: Int) {
        balance += n
    }

    fun rename(to: String) {
        owner = to
    }
}

fun main() {
    val a = Account()
    println(a.id)
    a.deposit(5)
    println(a.balance)
    a.rename("ada")
    println(a.owner)
}
