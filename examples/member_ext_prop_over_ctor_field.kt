// A member-extension property (`private val I.parent` inside `Wrapper`)
// belongs to the extension surface, not to `I`. A read `obj.parent` where
// `obj` is statically typed `I` -- an interface with no member `parent` --
// resolves to that in-scope extension getter, EVEN THOUGH the runtime object
// is an `Impl(val parent: String)` carrying a stored constructor-property
// field of the same name. Kotlin decides member-vs-extension by the STATIC
// receiver type, so the accidental runtime field is irrelevant. A read
// through the concrete static type `Impl`, whose member `parent` exists,
// still reads the field: a member outranks the extension.

interface I

class Impl(val parent: String) : I

class Wrapper {
    private val I.parent: String
        get() = "ext-parent"

    fun readViaInterface(obj: I): String = obj.parent
    fun readViaConcrete(obj: Impl): String = obj.parent
}

// The receiver may also be an enclosing constructor-property whose declared
// (interface) type carries no such member: `holder.value.tag` reads through
// the extension while the runtime `Boxed` field `tag` is shadowed.
interface Named
class Boxed(val tag: String) : Named
class Reader(val value: Named) {
    private val Named.tag: String
        get() = "ext-tag"

    fun read(): String = value.tag
}

fun main() {
    val impl = Impl("field-parent")
    println(Wrapper().readViaInterface(impl))
    println(Wrapper().readViaConcrete(impl))
    println(Reader(Boxed("field-tag")).read())
}
