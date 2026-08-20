// `@SerialName` renames what goes on the wire, without touching the Kotlin
// declaration. On a class it replaces the descriptor's serial name, which
// otherwise defaults to the qualified class name. On a property it replaces
// that element's name, while the property itself keeps its declared name for
// reading and constructing the value.
//
// Run with: klio run examples/serial_name_annotation.kt

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.serializer

@Serializable
@SerialName("account")
data class Account(
    val id: Int,
    @SerialName("display_name") val displayName: String,
    @SerialName("is_active") val active: Boolean = true,
)

@Serializable
data class Plain(val id: Int)

fun main() {
    val d = serializer<Account>().descriptor
    println("serialName=${d.serialName}")
    var i = 0
    while (i < d.elementsCount) {
        println("  element $i = ${d.getElementName(i)}")
        i = i + 1
    }

    // Without the annotation the serial name falls back to the class name.
    println("plain serialName=${serializer<Plain>().descriptor.serialName}")

    // The declaration keeps its Kotlin names regardless.
    val a = Account(7, "Ada")
    println("property displayName=${a.displayName} active=${a.active}")

    // Element lookup goes by wire name.
    println("indexOf display_name=${d.getElementIndex("display_name")}")
}
