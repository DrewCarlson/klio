// User extension functions on builtins and on a user class hierarchy.
// `this` inside the body refers to the call-site receiver; extensions
// declared on a parent class match instances of every subclass.

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
