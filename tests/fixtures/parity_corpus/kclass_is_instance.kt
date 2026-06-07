open class Animal
class Dog : Animal()

fun main() {
    println(String::class.isInstance("hi"))
    println(Int::class.isInstance("hi"))
    println(Int::class.isInstance(5))
    println(Animal::class.isInstance(Dog()))
    println(Dog::class.isInstance(Animal()))
    println(CharSequence::class.isInstance("x"))
}
