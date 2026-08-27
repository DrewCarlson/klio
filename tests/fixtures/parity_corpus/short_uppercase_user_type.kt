// A user type whose name looks like a type parameter (`R`, `T`, `E`) is a
// real declaration: receiver-type proofs must check it, not wave it through
// the way a bare type variable is waved through.

interface R {
    var out: String
}

class Cfg : R {
    override var out: String = ""
}

interface Sem {
    fun R.applySem()
}

class Focusable : Sem {
    override fun R.applySem() {
        out += "F"
    }
}

class Clickable(private val focus: Focusable) : Sem {
    override fun R.applySem() {
        out += "C"
        with(focus) { applySem() }
        out += "c"
    }
}

fun main() {
    val cfg = Cfg()
    with(Clickable(Focusable())) { cfg.applySem() }
    println(cfg.out)
}
