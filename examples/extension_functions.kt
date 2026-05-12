// M23 user extension functions: `fun T.foo()` declarations bind `this`
// at the call site and resolve through both the parser and the type
// checker. Extensions declared on a parent class match any subclass
// instance.

fun String.shout(): String = "${this}!"

open class Animal(val name: String)
class Dog(n: String): Animal(n)

fun Animal.greet(): String = "hello ${this.name}"

class Box(val n: Int)
fun Box.doubled(): Int = this.n * 2

fun main() {
    println("hi".shout())
    println(Dog("Rex").greet())
    println(Box(7).doubled())
}
