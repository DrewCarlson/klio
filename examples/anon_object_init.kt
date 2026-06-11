// Anonymous-object initialization: property initializers evaluate in the
// enclosing scope (top-level properties, object singletons, inline-HOF
// calls, captured locals), and supertype constructor arguments are real
// expressions over that scope.

object Palette {
    val accent = "teal"
    override fun toString(): String = "Palette($accent)"
}

val basePrice = 40

open class Item(val price: Int)

fun main() {
    // Initializers reading enclosing-scope names by bare identifier.
    val card = object {
        val theme = Palette
        val price = basePrice
        val label = run { "sku-" + (basePrice + 2) }
    }
    println(card.theme)
    println(card.price)
    println(card.label)

    // Supertype ctor args: a global, a compound expression, a captured local.
    val discount = 5
    val sale = object : Item(basePrice - discount) {
        val tag = "sale@" + price
    }
    println(sale.price)
    println(sale.tag)

    // An init block interleaves with property initializers and sees both
    // the captured local and the half-built object's earlier members.
    val audit = object {
        val opened = discount + 1
        init {
            println("audit: opened=$opened")
        }
        val closed = opened + 1
    }
    println(audit.closed)
}
