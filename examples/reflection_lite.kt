// M26: reflection-lite. `Foo::class` produces a KClass with
// `simpleName` / `qualifiedName`. `Foo::name` produces a property
// reference whose `.get(receiver)` reads the named field. `::topFn`
// and `Foo::method` produce callable references with `.call(args)`
// and direct invocation.

class Person(val name: String, val age: Int)

fun greet(who: String): String = "hello, $who"

fun main() {
    val p = Person("Alice", 30)

    val cls = Person::class
    println(cls.simpleName)

    val nameRef = Person::name
    println(nameRef.name)
    println(nameRef.get(p))

    val ageRef = Person::age
    println(ageRef.get(p))

    val gref = ::greet
    println(gref("world"))
    println(gref("kotlin"))

    val ctor = ::Person
    val q = ctor("Bob", 25)
    println(q.name)
    println(q.age)
}
