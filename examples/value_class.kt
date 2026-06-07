value class UserId(val raw: Int)
value class Email(val address: String)

fun describe(id: UserId, e: Email): String = "user=${id.raw} email=${e.address}"

fun main() {
    val u = UserId(7)
    val e = Email("alice@example.com")
    println(u.raw)
    println(e.address)
    println(describe(u, e))
}
