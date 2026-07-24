package renamed.function.imports.app

import renamed.function.imports.lib.choose as original
import renamed.function.imports.lib.merge as collected
import renamed.function.imports.lib.Pipe
import renamed.function.imports.lib.rewrite as transform

fun String.extensionCall(): String = original("b")

inline fun Pipe.map(transform: (Int) -> Int): Int =
    transform { value -> transform(value) }

fun main() {
    println("a".extensionCall())
    println(original("a", "b", "c"))
    println(original("a", "b", "c", "d"))
    println(collected(*arrayOf("x", "y")))
    val plain: (String, String, String) -> String = ::original
    println(plain("r", "s", "t"))
    val unbound: (String, String) -> String = String::original
    println(unbound("u", "v"))
    val bound: (String) -> String = "w"::original
    println(bound("x"))
    println(Pipe(3).map { it * 10 })
}
