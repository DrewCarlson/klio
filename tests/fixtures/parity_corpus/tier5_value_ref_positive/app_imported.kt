package app
import lib.helper
import lib.flag
import lib.Box
import lib.greet
import lib.sum
import lib.combo
import lib.vlam
fun main() {
    val f = ::helper; println(f())
    println(flag)
    val c = ::Box; println(c(3).n)
    println(greet())
    println(sum(1,2,3))
    println(combo { })
    println(vlam(1,2) { })
}
