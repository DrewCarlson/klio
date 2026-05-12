package demo.app

import kotlin.math.PI
import kotlin.collections.List as KList

class Box(val value: Int) {
    fun get(): Int = value
}

object Singleton {
    val name = "singleton"
}

interface Greeter {
    fun greet(): String
}

fun main() {
    val b: Box = Box(1)
    var counter: Int = 0
    counter += b.get()
    if (counter > 0) {
        return
    }
    while (counter < 10) {
        counter++
    }
    for (i in 0..3) {
        println(i)
    }
}
