// A bare reference to an interface's own companion object resolves to that
// companion — from the interface's own default member, from an implementing
// class's method, and through a companion that carries a supertype (the
// CoroutineContext.Element pattern, where `companion object Key :
// CoroutineContext.Key<…>` is also a classifier).
import kotlin.coroutines.CoroutineContext

interface Named {
    val tag: String get() = Tag.label          // bare companion in a default member
    companion object Tag {
        const val label: String = "named"
    }
}

class Widget : Named {
    fun viaImpl(): String = Tag.label           // bare companion from an implementor
}

interface Element : CoroutineContext.Element {
    override val key: CoroutineContext.Key<*> get() = Key   // companion with a supertype
    companion object Key : CoroutineContext.Key<Element>
}

class MyElement : Element

fun main() {
    println(Widget().tag)                        // named
    println(Widget().viaImpl())                  // named
    println(MyElement().key === Element.Key)     // true
}
