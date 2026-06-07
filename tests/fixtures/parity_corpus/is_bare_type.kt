interface Foo<A, B>
class Fee<T, U>: Foo<U, T>

fun examine(foo: Foo<String, Int>) {
    println(foo is Fee<*, *>)
    println(foo is Fee)
}

fun main() {
    examine(Fee())
}
