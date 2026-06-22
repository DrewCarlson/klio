// Concrete stand-ins for the `test.collections.js` expect factories, whose
// actuals live in platform test source sets KLIO's commonTest sweep does not
// compile. Mirrors the JVM test actuals.
package test.collections.js

fun <V> stringMapOf(vararg pairs: Pair<String, V>): HashMap<String, V> = hashMapOf<String, V>(*pairs)
fun <V> linkedStringMapOf(vararg pairs: Pair<String, V>): LinkedHashMap<String, V> = linkedMapOf(*pairs)
fun stringSetOf(vararg elements: String): HashSet<String> = hashSetOf(*elements)
fun linkedStringSetOf(vararg elements: String): LinkedHashSet<String> = linkedSetOf(*elements)
