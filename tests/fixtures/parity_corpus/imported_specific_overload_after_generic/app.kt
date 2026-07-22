package app

import cells.cell

class GenericHolder<T>(value: T) {
    val ref = cell(value)
}

class IntHolder(value: Int) {
    val ref = cell(value)
}

fun main() {
    println(GenericHolder("x").ref.label)
    println(IntHolder(1).ref.label)
}
