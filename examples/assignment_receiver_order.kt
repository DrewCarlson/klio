// A member assignment evaluates its receiver before the value; a prefix or
// postfix increment of a member reached through a call evaluates that
// call once; a compound assignment to a member does the same.
var log = ""

class A {
    var prop: Int = 0
    var x: Int = 0
}

fun bar(tag: String, a: A): A {
    log += tag
    return a
}

fun main() {
    val a = A()
    bar("A", a).prop = try { log += "B"; 10 } finally {}
    println("$log ${a.prop}")
    log = ""
    val old = bar("G", a).x++
    println("$log $old ${a.x}")
    log = ""
    bar("P", a).prop += 5
    println("$log ${a.prop}")
}
