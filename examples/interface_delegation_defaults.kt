// Class delegation (`class W(d: I) : I by d`) forwards EVERY member of the
// delegated interface that the class does not override — including members the
// interface gives a default body. A default is what an implementor inherits
// when it declares nothing; a delegating class declares the delegate instead,
// so the delegate's answer is the one that counts.
//
// Run with: klio run examples/interface_delegation_defaults.kt

interface Source {
    val id: String
    // Abstract members: nothing to inherit, so forwarding is the only option.
    fun read(i: Int): String
    // Defaulted members: the interface body must NOT win over the delegate.
    val tags: List<String> get() = emptyList()
    val size: Int get() = tags.size
    fun describe(): String = "Source(" + id + ")"
    fun label(prefix: String): String = prefix + "/" + id
}

class Real(override val id: String, override val tags: List<String>) : Source {
    override fun read(i: Int): String = tags[i]
    override fun describe(): String = "Real(" + id + "," + tags + ")"
    override fun label(prefix: String): String = "real:" + prefix + ":" + id
}

// Overrides `id` only; everything else is the delegate's.
class Renamed(private val inner: Source) : Source by inner {
    override val id: String get() = "renamed(" + inner.id + ")"
}

// Overrides a DEFAULTED member: the class's own body wins over both.
class Quiet(private val inner: Source) : Source by inner {
    override fun describe(): String = "Quiet"
}

// A delegate that itself inherits the interface defaults: forwarding reaches
// the default through the delegate, not through the wrapper.
class Bare(override val id: String) : Source {
    override fun read(i: Int): String = "none"
}

// An anonymous object delegates the same way, and its own overrides win —
// including over an ABSTRACT member the delegate would otherwise answer.
fun wrapAnon(inner: Source): Source = object : Source by inner {
    override fun read(i: Int): String = "anon:" + inner.read(i)
    override val tags: List<String> get() = listOf("anon")
}

fun main() {
    val real = Real("r", listOf("x", "y"))

    val a: Source = Renamed(real)
    println("id       = " + a.id)
    println("tags     = " + a.tags)
    println("size     = " + a.size)
    println("read     = " + a.read(1))
    println("describe = " + a.describe())
    println("label    = " + a.label("p"))

    val b: Source = Quiet(real)
    println("q.id     = " + b.id)
    println("q.desc   = " + b.describe())
    println("q.label  = " + b.label("p"))

    val c: Source = Renamed(Bare("bare"))
    println("bare id  = " + c.id)
    println("bare tags= " + c.tags)
    println("bare size= " + c.size)
    println("bare desc= " + c.describe())

    // Delegation nests: each layer forwards what it does not declare.
    val d: Source = Quiet(Renamed(real))
    println("nest id  = " + d.id)
    println("nest desc= " + d.describe())
    println("nest lbl = " + d.label("n"))

    val e = wrapAnon(real)
    println("anon id  = " + e.id)
    println("anon read= " + e.read(0))
    println("anon tags= " + e.tags)
    println("anon size= " + e.size)
    println("anon desc= " + e.describe())

    // Dispatch through the interface stays virtual for non-delegating types.
    val all: List<Source> = listOf(real, Bare("z"), Renamed(real))
    println("all      = " + all.map { it.describe() })
}
