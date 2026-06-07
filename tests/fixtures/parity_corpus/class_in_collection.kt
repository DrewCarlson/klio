data class User(val name: String, val age: Int)

fun main() {
    val users = listOf(
        User("alice", 30),
        User("bob", 25),
        User("carol", 35),
    )
    println(users.size)
    println(users)
    val names = users.map { it.name }
    println(names)
    val adults = users.filter { it.age >= 30 }
    println(adults)
    val joined = users.joinToString(", ") { it.name }
    println(joined)
}
