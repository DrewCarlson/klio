fun String.shout() {
    run {
        println(this@shout)
        println(this@shout.length)
    }
}

fun main() {
    "hi".shout()
}
