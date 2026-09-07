// A `lateinit var` read before its first assignment throws
// `UninitializedPropertyAccessException` naming the property, wherever it
// is declared: a top-level (including file-private) property, an object or
// class member read directly, through an accessor or from the owning
// class's companion, and a local — read plainly, in a string template,
// through a member access, from a lambda, an anonymous object or a local
// function that captures it, or by a compound assignment. `::name.isInitialized`
// answers without throwing, and a same-named plain local shadows the
// lateinit without inheriting its check.
// Run with: klio run examples/lateinit_uninitialized_access.kt
lateinit var top: String
private lateinit var filePrivate: String

object Holder {
    lateinit var name: String
    fun read() = name
}

class Box {
    lateinit var value: String
    fun readValue() = value
    fun initialized() = ::value.isInitialized
    fun fromCompanion() = tag
    companion object {
        lateinit var tag: String
    }
}

fun <T> eval(f: () -> T) = f()

fun probe(label: String, f: () -> Any?) {
    try {
        println("$label = ${f()}")
    } catch (e: UninitializedPropertyAccessException) {
        println("$label threw ${e::class.simpleName}: ${e.message}")
    }
}

fun main() {
    println("top initialized: ${::top.isInitialized}")
    probe("top") { top }
    probe("top.length") { top.length }
    top = "set"
    println("top initialized: ${::top.isInitialized}")
    probe("top") { top }
    probe("filePrivate") { filePrivate }
    filePrivate = "fp"
    probe("filePrivate") { filePrivate }

    probe("Holder.read") { Holder.read() }
    Holder.name = "holder"
    probe("Holder.read") { Holder.read() }
    val b = Box()
    println("box initialized: ${b.initialized()} ${b::value.isInitialized}")
    probe("box.readValue") { b.readValue() }
    probe("box.value") { b.value }
    b.value = "boxed"
    println("box initialized: ${b.initialized()} ${b::value.isInitialized}")
    probe("box.value") { b.value }
    probe("Box.tag via instance") { b.fromCompanion() }
    probe("Box.tag") { Box.tag }
    Box.tag = "tagged"
    probe("Box.tag via instance") { b.fromCompanion() }

    lateinit var local: String
    probe("local") { local }
    probe("local.length") { local.length }
    probe("template") { "<$local>" }
    probe("eval") { eval { local } }
    var captured = ""
    probe("captured read") { eval { captured = local; captured } }
    local = "local"
    probe("local") { local }
    probe("eval") { eval { local } }

    lateinit var written: String
    eval { written = "written in lambda" }
    probe("written") { written }

    lateinit var shadow: String
    run {
        val shadow: String? = null
        println("inner shadow = $shadow")
    }
    probe("outer shadow") { shadow }

    lateinit var acc: String
    probe("acc +=") { acc += "x"; acc }
    acc = "a"
    acc += "b"
    probe("acc") { acc }

    lateinit var forObj: String
    val o = object { fun get() = forObj }
    fun readIt() = forObj
    probe("anon object") { o.get() }
    probe("local fn") { readIt() }
    forObj = "obj"
    probe("anon object") { o.get() }
    probe("local fn") { readIt() }
}
