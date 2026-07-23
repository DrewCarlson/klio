class Foo {
    fun tag(): String = "Foo"
}

class Bar {
    fun tag(): String = "Bar"
}

class Host {
    fun Foo(): Bar = Bar()

    fun run() {
        val value = Foo()
        println(value.tag())
    }
}

fun main() {
    Host().run()
}
