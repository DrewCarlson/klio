interface A { fun f() = println("A") }
interface B { fun f() = println("B") }
interface C { fun f() = println("C") }

class D : A, B {
    override fun f() {
        super<C>.f()
    }
}
