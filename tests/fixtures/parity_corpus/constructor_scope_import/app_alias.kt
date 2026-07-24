package constructor.scope.alias

import constructor.scope.lib.Token as RightToken

fun RightToken(value: Int): String = "factory"

fun main() {
    println(RightToken(1))
}
