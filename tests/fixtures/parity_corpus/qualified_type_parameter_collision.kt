package app

class Key
class Word

class Scope<Key> {
    fun pick(value: app.Key): String = "member"
}

fun Scope<Int>.pick(value: Word): String = "extension:class"

fun make(): Scope<Int> = Scope<Int>()

class FunctionScope {
    fun <Key> pick(value: app.Key): String = "member"
}

fun FunctionScope.pick(value: Word): String = "extension:function"

open class Base<T> {
    open fun <T> pick(value: T): String = "base"
}

class Derived<X> : Base<X>() {
    override fun <T> pick(value: T): String = "derived"
}

fun call(base: Base<Int>): String = base.pick("x")

fun main() {
    println(make().pick(Word()))
    println(FunctionScope().pick(Word()))
    println(call(Derived<Int>()))
}
