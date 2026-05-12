value class UserId(val raw: Int)
value class Email(val address: String)

fun main() {
    val u = UserId(7)
    val e = Email("a@b.c")
    println(u.raw)
    println(e.address)
}
