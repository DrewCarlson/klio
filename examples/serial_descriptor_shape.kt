// The SerialDescriptor a `@Serializable` class reports: element names, which
// elements are optional, and each element's own descriptor.
//
// An element is *optional* when its primary-constructor parameter has a
// default — a decoder may leave it out of the input. An element's descriptor
// names the element's own type, so `port` reports `kotlin.Int` and a nullable
// element reports the `?`-suffixed name upstream gives it.
//
// An element annotated `@SerialName` reports that WIRE name, while the
// property keeps its declared name for reading and constructing the value.
//
// Run with: klio run examples/serial_descriptor_shape.kt

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.serializer

@Serializable
data class Config(
    val host: String,
    val port: Int = 8080,
    val debug: Boolean? = null,
    @SerialName("max_retries") val maxRetries: Int = 3,
)

fun main() {
    val d = serializer<Config>().descriptor
    println("elements=${d.elementsCount}")
    var i = 0
    while (i < d.elementsCount) {
        val e = d.getElementDescriptor(i)
        println("${d.getElementName(i)} optional=${d.isElementOptional(i)} type=${e.serialName}")
        i = i + 1
    }
}
