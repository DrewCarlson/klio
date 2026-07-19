// Two classes share a simple name in different namespaces (nested in distinct
// outer classes, so their fully-qualified names differ) and each carries its
// OWN same-named extension reading a field only it declares. klio records an
// extension's receiver by its simple name, so both `Entry.tag` extensions look
// applicable to any `Entry`; the runtime receiver's actual class must decide
// which twin binds — the sibling would read a field the object lacks. Each
// `make*` factory hides the concrete type behind an inferred return, so the
// receiver reaches the runtime pick with an erased static type (the shape the
// compose engine hits with its gapbuffer / linkbuffer `SlotTable` twins).
interface Node

class Registry {
    class Entry : Node {
        val registryTag = "registry"
    }
}

class Catalog {
    class Entry : Node {
        val catalogTag = "catalog"
    }
}

fun Registry.Entry.tag(): String = registryTag

fun Catalog.Entry.tag(): String = catalogTag

fun makeRegistryEntry() = Registry.Entry()

fun makeCatalogEntry() = Catalog.Entry()

fun main() {
    println(makeRegistryEntry().tag())
    println(makeCatalogEntry().tag())
}
