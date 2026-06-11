// An assignment LHS resolves only to properties/variables: a member
// *function* of the written name never captures a bare write, at any
// receiver depth; compound assignment reads and writes the same binding.
class Holder { fun label(): String = "fn" }
class OuterFn { fun tag(): String = "fn" }
class Inner
class Counter { fun count(): Int = 99 }
var label: String = "global"
var tag = "global"
var count = 10
fun main() {
    with(Holder()) { label = "written" }
    println(label)
    with(OuterFn()) { with(Inner()) { tag = "written" } }
    println(tag)
    with(Counter()) { count += 5 }
    println(count)
}
