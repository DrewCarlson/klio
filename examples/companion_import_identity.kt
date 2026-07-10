// A named companion-member import aliases the SAME value the qualified
// read yields, and outranks a same-named class in expression position.

import Registry.Companion.Token
import Registry.Companion.Marker

interface Marker

class Registry {
    companion object {
        val Token = Any()
        val Marker = Any()
        const val Limit = Int.MAX_VALUE
    }
}

fun main() {
    println("token=" + (Token === Registry.Token))
    println("collide=" + (Marker === Registry.Marker))
    println("limit=" + Registry.Limit)
}
