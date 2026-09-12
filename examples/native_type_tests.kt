// `is` and `as` compiled to C. Which classes answer a type test is decided when
// the program is compiled: the emitter knows the hierarchy it laid out, so the
// test on a compiled instance is a comparison against the class handles that
// reach the named type. A value that is not a compiled instance — a string, a
// number, a list — answers from its own representation, the way it answers the
// interpreter.
open class Animal(val name: String)
class Dog(name: String) : Animal(name)
class Cat(name: String) : Animal(name)

fun describe(a: Any): String {
    if (a is Dog) return "dog"
    if (a is Animal) return "animal"
    if (a is String) return "string"
    if (a is Int) return "int"
    return "other"
}

fun main() {
    println(describe(Dog("rex")))
    println(describe(Cat("tom")))
    println(describe(Animal("generic")))
    println(describe("hi"))
    println(describe(4))
    println(describe(1.5))

    // `as` narrows: the register carries the named type afterwards, which is
    // what lets its members be read.
    val a: Any = Dog("fido")
    println((a as Dog).name)
    println((a as Animal).name)

    // A failed `as` is a ClassCastException a handler in the same program
    // catches; `as?` answers null instead.
    val c: Any = Cat("mia")
    try {
        val d = c as Dog
        println(d.name)
    } catch (e: ClassCastException) {
        println("caught")
    }
    println((c as? Dog) == null)
}
