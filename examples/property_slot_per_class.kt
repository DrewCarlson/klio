// A property declared on an interface or an abstract class is answered
// differently by every implementation, so a read of it names no accessor and
// no cell — it names the PROPERTY, and the receiver's class picks. Each shape
// below answers `label` its own way, and reading through the declared type has
// to reach the implementation rather than the declaration.
//
// The last three cases are the ones that make a per-class table hard: a
// primary-constructor property overriding an accessor, a class that holds its
// state in a delegate, and a subclass replacing a stored property with a
// getter.
//
// Run with: klio run examples/property_slot_per_class.kt

interface Named {
    val label: String
    val width: Int
}

// Answers from a stored cell.
class Plain(override val label: String) : Named {
    override val width: Int = label.length
}

// Answers by running an accessor.
class Shouted(private val base: String) : Named {
    override val label: String
        get() = base.uppercase()
    override val width: Int
        get() = base.length * 2
}

// Answers by forwarding to another object entirely.
class Wrapped(inner: Named) : Named by inner

// An open class whose stored property a subclass replaces with a getter.
open class Tagged(open val label: String) {
    open val width: Int = 1
}

class Counted(private val n: Int) : Tagged("counted") {
    override val label: String
        get() = "counted:$n"
    override val width: Int
        get() = n
}

// A constructor property overriding a supertype's accessor: the declaration
// lives in the parameter list, not the body.
abstract class Status {
    open val code: Int
        get() = 200
}

class Created(override val code: Int = 201) : Status()

class Defaulted : Status()

fun describe(n: Named): String = "${n.label}/${n.width}"

fun describeTagged(t: Tagged): String = "${t.label}/${t.width}"

fun main() {
    val shapes: List<Named> = listOf(
        Plain("plain"),
        Shouted("shout"),
        Wrapped(Plain("wrapped")),
    )
    for (s in shapes) println(describe(s))

    println(describeTagged(Tagged("tagged")))
    println(describeTagged(Counted(7)))

    println(Created().code)
    println(Created(204).code)
    println(Defaulted().code)

    // Through the exact type, where the override is directly visible.
    println(Counted(3).label)
    println(Shouted("exact").width)
}
