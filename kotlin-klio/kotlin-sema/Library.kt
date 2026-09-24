// klio `actual`s the sema pipeline uses for the top-level declarations of
// Library.kt the name-resolving interpreter serves from the host by name.

package kotlin

public actual fun Any?.toString(): String = if (this == null) "null" else this.toString()
