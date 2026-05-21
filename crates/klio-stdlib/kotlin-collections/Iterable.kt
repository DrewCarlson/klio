// klio commonMain shipment of the simplest Iterable<T> extension
// functions. Each is the upstream verbatim body, stripped of the
// `if (this is Collection)` fast-path (klio's runtime List/Set
// don't satisfy `is Collection` so the slow path is the only one
// taken anyway, and the slow path is correct on its own).
//
// These cover the high-frequency aggregation / projection /
// filtering operators klio used to implement as Rust intrinsics
// (`coll_iter_for_each`, `coll_iter_map`, `coll_iter_filter`,
// `coll_iter_any`, `coll_iter_all`, `coll_iter_none`,
// `coll_list_count_no_pred`, `coll_iter_filter_not_null`). The
// per-type-prefix TABLE entries in
// `crates/klio-stdlib/src/implementations.rs` are removed alongside
// this file — the call-site dispatcher's extension-fallback path
// finds these `Iterable<T>` extensions and routes through them.

package kotlin.collections

public inline fun <T> Iterable<T>.forEach(action: (T) -> Unit): Unit {
    for (element in this) action(element)
}

public inline fun <T, C : MutableCollection<in T>> Iterable<T>.filterTo(
    destination: C,
    predicate: (T) -> Boolean,
): C {
    for (element in this) if (predicate(element)) destination.add(element)
    return destination
}

public inline fun <T> Iterable<T>.filter(predicate: (T) -> Boolean): List<T> =
    filterTo(ArrayList<T>(), predicate)

public fun <T : Any> Iterable<T?>.filterNotNullTo(destination: MutableCollection<in T>): MutableCollection<in T> {
    for (element in this) if (element != null) destination.add(element)
    return destination
}

public fun <T : Any> Iterable<T?>.filterNotNull(): List<T> {
    val out = ArrayList<T>()
    for (element in this) if (element != null) out.add(element)
    return out
}

public inline fun <T, R, C : MutableCollection<in R>> Iterable<T>.mapTo(
    destination: C,
    transform: (T) -> R,
): C {
    for (item in this) destination.add(transform(item))
    return destination
}

public inline fun <T, R> Iterable<T>.map(transform: (T) -> R): List<R> =
    mapTo(ArrayList<R>(), transform)

public fun <T> Iterable<T>.any(): Boolean {
    for (@Suppress("UNUSED_VARIABLE") element in this) return true
    return false
}

public inline fun <T> Iterable<T>.any(predicate: (T) -> Boolean): Boolean {
    for (element in this) if (predicate(element)) return true
    return false
}

public inline fun <T> Iterable<T>.all(predicate: (T) -> Boolean): Boolean {
    for (element in this) if (!predicate(element)) return false
    return true
}

public fun <T> Iterable<T>.none(): Boolean {
    for (@Suppress("UNUSED_VARIABLE") element in this) return false
    return true
}

public inline fun <T> Iterable<T>.none(predicate: (T) -> Boolean): Boolean {
    for (element in this) if (predicate(element)) return false
    return true
}

public fun <T> Iterable<T>.count(): Int {
    var n = 0
    for (@Suppress("UNUSED_VARIABLE") element in this) n++
    return n
}

public inline fun <T> Iterable<T>.count(predicate: (T) -> Boolean): Int {
    var n = 0
    for (element in this) if (predicate(element)) n++
    return n
}
