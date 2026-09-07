// A member brought into scope by `import Object.member` is the object's
// property everywhere it is spelled bare: plain reads, reads inside a
// string template, assignments, compound assignments and increments all go
// through the object.
import Host.count
import Host.label

object Host {
    var count = 0
    var label = "a"
}

fun main() {
    count += 1
    println("$count ${Host.count}")
    count++
    ++count
    println(count == Host.count && count == 3)
    label = label + "b"
    println("$label ${Host.label}")
}
