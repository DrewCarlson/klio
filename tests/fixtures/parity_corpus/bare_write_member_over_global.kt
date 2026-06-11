// An enclosing receiver's member outranks a same-named top-level `var` for
// a bare-name write: `label = "written"` inside the nested lambdas mutates
// `o.label`, leaving the file-scope `label` untouched.
class Outer {
    var label: String = "init"
}

class Gadget {
    var size: Int = 0
}

var label: String = "global"

fun main() {
    val o = Outer()
    with(o) {
        with(Gadget()) {
            label = "written"
        }
    }
    println(o.label)
    println(label)
}
