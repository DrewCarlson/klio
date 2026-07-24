package constructor.scope.app

import constructor.scope.lib.Token

fun Token(value: Int): String = "factory"

fun main() {
    println(Token(1))
}
