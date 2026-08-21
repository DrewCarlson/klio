import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*

@SerialInfo
@Target(AnnotationTarget.CLASS)
annotation class CA(val value: String)

@CA("x") class Marked

class Wrap(val tag: String) {
    constructor(tag: String, anns: Array<Annotation>) : this(tag) { _annotations = anns.asList() }
    private var _annotations: List<Annotation> = emptyList()

    val plain: SerialDescriptor by lazy(LazyThreadSafetyMode.PUBLICATION) {
        buildSerialDescriptor(tag + "-plain", StructureKind.OBJECT) {
            annotations = _annotations
        }
    }
    val withElements: SerialDescriptor by lazy(LazyThreadSafetyMode.PUBLICATION) {
        buildSerialDescriptor(tag + "-el", PolymorphicKind.OPEN) {
            element("type", String.serializer().descriptor)
            element("value", buildSerialDescriptor(tag + "-inner", SerialKind.CONTEXTUAL))
            annotations = _annotations
        }
    }
    val ctxWrapped: SerialDescriptor by lazy(LazyThreadSafetyMode.PUBLICATION) {
        buildSerialDescriptor(tag + "-ctx", PolymorphicKind.OPEN) {
            element("type", String.serializer().descriptor)
            annotations = _annotations
        }
    }
}

fun main() {
    val anns = __klsx_classAnnotations(Marked::class).toTypedArray()
    val w = Wrap("W", anns)
    println("plain=" + w.plain.annotations)
    println("withElements=" + w.withElements.annotations)
    println("ctxWrapped=" + w.ctxWrapped.annotations)
}
