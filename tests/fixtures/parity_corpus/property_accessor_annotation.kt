// A property accessor may carry an annotation (`@Ann get()`, `@Ann set(v)`,
// `@Ann set` with a use-site target, and annotated bodyless setters). klio
// ignores accessor annotations; the parser must accept them.
@Target(AnnotationTarget.PROPERTY_GETTER, AnnotationTarget.PROPERTY_SETTER)
annotation class Marker

@Target(AnnotationTarget.PROPERTY_SETTER)
annotation class Named(val n: String)

class Box {
    var value: Int = 0
        @Marker get() = field
        @Named("v") set(v) {
            field = v * 2
        }

    var label: String = "init"
        @Marker public set
}

fun main() {
    val b = Box()
    b.value = 5
    println(b.value)
    b.label = "changed"
    println(b.label)
}
