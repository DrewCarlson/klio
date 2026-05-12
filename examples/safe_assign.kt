class Address(var city: String)
class Person(var address: Address?)

fun update(p: Person?, city: String) {
    p?.address?.city = city
}

fun main() {
    val alice = Person(Address("Springfield"))
    update(alice, "Portland")
    println(alice.address?.city)
    val bob = Person(null)
    update(bob, "Anywhere")
    println(bob.address?.city)
    update(null, "Nowhere")
    println("done")
}
