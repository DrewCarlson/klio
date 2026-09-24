// `ListHead` reaches this file only through the star import of
// `sample.linked`, so the subclass extends that one, whatever else the
// program declares under the same simple name.
package sample.app

import sample.linked.*

class NodeList : ListHead() {
    fun size(): Int = marker
}

fun main() {
    val list = NodeList()
    println(list.describe())
    println(list.size())
    println(list is sample.linked.ListHead)
}
