// An inline extension's parameter binding must not capture a LATER argument
// expression that uses the same name as an EARLIER parameter: the arguments
// are caller code and evaluate in the caller's scope. `push(0, address)`
// with a caller local `address` must pass the local's value, not the
// just-bound `address` parameter (which is 0). Only a default-filled
// parameter is callee code that sees the earlier parameters.

const val NEXT = 1

inline fun IntArray.link(address: Int, value: Int) {
    this[address + NEXT] = value
}

inline fun IntArray.link(address: Int) = this[address + NEXT]

inline fun order(first: Int, second: Int, third: Int = first + second): Int =
    first * 100 + second * 10 + third

fun main() {
    val a = IntArray(8) { -1 }
    val address = 4
    a.link(0, address)
    println(a[1])
    a.link(address, a.link(0))
    println(a[5])

    val first = 3
    val second = 7
    println(order(second, first))
    println(order(1, 2, first))
}
