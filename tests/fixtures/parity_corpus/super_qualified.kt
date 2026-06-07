interface A { fun greet() { println("A") } }
interface B { fun greet() { println("B") } }

class C : A, B {
    override fun greet() {
        super<A>.greet()
        super<B>.greet()
    }
}

fun main() {
    C().greet()
}
