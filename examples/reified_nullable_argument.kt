// A reified type argument written `T?`, where `T` is the enclosing inline
// function's own reified parameter, is the type `T` stands for marked
// nullable: `impl<T?>()`, `null.impl<T?>()` and `List<T?>` inside it. A
// `T?` for a `T` that is already nullable stays what it is.
import kotlin.reflect.KClass
import kotlin.reflect.typeOf

inline fun <reified T : Any> T.outer() {
    this.impl<T>("T")
    this.impl<T?>("T?")
    null.impl<T?>("null as T?")
    impl2<List<T?>>("List<T?>")
    impl2<Map<String, T?>>("Map<String, T?>")
}

inline fun <reified T> T.impl(label: String) {
    val t = typeOf<T>()
    println("$label: " + (t.classifier as KClass<*>).simpleName + ", marked nullable " + t.isMarkedNullable)
}

inline fun <reified T> impl2(label: String) {
    val t = typeOf<T>()
    val args = t.arguments.map { a ->
        val at = a.type!!
        (at.classifier as KClass<*>).simpleName + (if (at.isMarkedNullable) "?" else "")
    }
    println("$label: " + (t.classifier as KClass<*>).simpleName + args)
}

inline fun <reified T> alreadyNullable(label: String) {
    val t = typeOf<T?>()
    println("$label: " + (t.classifier as KClass<*>).simpleName + ", marked nullable " + t.isMarkedNullable)
}

fun main() {
    Byte.MIN_VALUE.outer()
    "s".outer()
    alreadyNullable<Int?>("Int? as T?")
    alreadyNullable<Int>("Int as T?")
}
