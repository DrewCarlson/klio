package app

import themed.render

class Host {
    private fun nested(block: () -> Unit) = block()

    fun run() {
        nested {
            render { println("content") }
        }
    }
}

fun main() {
    Host().run()
}
