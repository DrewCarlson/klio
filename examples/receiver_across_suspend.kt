// Enclosing-`this` (implicit receiver) context must survive a coroutine park.
// A member-extension body, or a method whose receiver is established through a
// nested scope, suspends at a `delay` and then references a bare member of an
// *enclosing* receiver after resume. That enclosing receiver is reachable only
// through the implicit-receiver chain (it is neither the body's own `this`
// param nor a closed-over capture), so the chain must travel with the parked
// continuation and be restored verbatim on resume. Each section prints a line
// that can only be produced if the enclosing receiver resolved correctly after
// the park.
import kotlinx.coroutines.*

class Helper {
    val hid = "H"
    fun localTag(): String = "helper=$hid"
}

class Owner(val oid: String) {
    fun owned(): String = "owner=$oid"

    // A suspend member-extension on Helper declared inside Owner. Its body's
    // own `this` is the Helper receiver (`localTag()` / `hid`), while `owned()`
    // resolves to the enclosing `this@Owner` — reachable only via the implicit
    // receiver chain. The `delay` parks the body; after resume both the inner
    // receiver and the enclosing receiver must still resolve.
    suspend fun Helper.process(): String {
        val before = "$hid:${owned()}"
        delay(5)
        val after = "${localTag()}:${owned()}"
        return "$before|$after"
    }

    suspend fun drive(h: Helper): String = h.process()
}

fun main() = runBlocking {
    // Two distinct Owners interleave: their member-extension bodies park and
    // resume, and each must resolve its OWN enclosing receiver after the park —
    // innermost (the matching Owner) wins, not whichever ran last.
    val a = Owner("A")
    val b = Owner("B")
    val h = Helper()

    val ra = async { a.drive(h) }
    val rb = async { b.drive(h) }
    println(ra.await())
    println(rb.await())

    // Sequential: an enclosing receiver referenced strictly after the park.
    println(Owner("seq").drive(h))
}
