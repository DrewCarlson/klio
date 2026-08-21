import kotlin.reflect.KClass

class SD(val serialName: String, val kind: String, val annotations: List<String>) {
    override fun toString() = "$serialName/$kind/$annotations"
}
class SDB(val serialName: String) {
    val elementNames = ArrayList<String>()
    var annotations: List<String> = emptyList()
    fun element(name: String, d: SD, annotations: List<String> = emptyList(), isOptional: Boolean = false) { elementNames.add(name) }
}
fun buildSD(serialName: String, kind: String, vararg tp: SD, builder: SDB.() -> Unit = {}): SD {
    val b = SDB(serialName)
    b.builder()
    return SD(serialName, kind, b.annotations)
}
fun SD.withContext(k: KClass<*>): SD = SD("$serialName<${k.simpleName}>", kind, annotations)

abstract class APS<T : Any> {
    abstract val baseClass: KClass<T>
}

class PS<T : Any>(override val baseClass: KClass<T>) : APS<T>() {
    internal constructor(baseClass: KClass<T>, classAnnotations: Array<String>) : this(baseClass) {
        _annotations = classAnnotations.asList()
    }
    private var _annotations: List<String> = emptyList()
    val descriptor: SD by lazy(LazyThreadSafetyMode.PUBLICATION) {
        buildSD("Poly", "OPEN") {
            element("type", SD("S", "STR", emptyList()))
            element("value", buildSD("Poly<${baseClass.simpleName}>", "CONTEXTUAL"))
            annotations = _annotations
        }.withContext(baseClass)
    }
}

class Target
fun main() {
    val p = PS(Target::class, arrayOf("A1"))
    println(p.descriptor)
}
