annotation class MyAnn

fun main() {
    for (@MyAnn x in 1..3) {
        println(x)
    }
}
