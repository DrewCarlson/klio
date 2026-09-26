// Open (sema/lowering): a reified type argument written `T?`, where T is the
// enclosing inline function's own reified parameter, loses its `?` on klio
// (every `T?` line prints kotlin.Byte / kotlin.String, marked nullable false,
// and List<T?> prints List<kotlin.Byte>). savedstate's codec tests fail on it
// (encodeDecodeImpl<T?> picks the non-null serializer). Expected, kotlinc
// 2.4.20:
//   T: kotlin.Byte, marked nullable false
//   T?: kotlin.Byte?, marked nullable true
//   null as T?: kotlin.Byte?, marked nullable true
//   List<T?>: kotlin.collections.List<kotlin.Byte?>
//   T: kotlin.String, marked nullable false
//   T?: kotlin.String?, marked nullable true
//   null as T?: kotlin.String?, marked nullable true
//   List<T?>: kotlin.collections.List<kotlin.String?>

import kotlin.reflect.typeOf

inline fun <reified T : Any> T.outer() {
    this.impl<T>("T")
    this.impl<T?>("T?")
    null.impl<T?>("null as T?")
    impl2<List<T?>>("List<T?>")
}

inline fun <reified T> T.impl(label: String) {
    println("$label: " + typeOf<T>() + ", marked nullable " + typeOf<T>().isMarkedNullable)
}

inline fun <reified T> impl2(label: String) {
    println("$label: " + typeOf<T>())
}

fun main() {
    Byte.MIN_VALUE.outer()
    "s".outer()
}
