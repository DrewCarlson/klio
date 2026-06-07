// klio JSON format for kotlinx-serialization.
//
// kotlinx-serialization's JSON module is a large reified-generic +
// streaming-codec body the klio parser does not accept, so the pack
// supplies a focused replacement: `Json.encodeToString` /
// `decodeFromString` route through host bindings (src/lib.rs) that
// encode reflectively over the runtime value and decode by walking the
// target class's primary-constructor parameter types. Config flags that
// affect the wire form (`prettyPrint`) are honored; the rest are stored
// for API compatibility.

package kotlinx.serialization.json

import kotlin.reflect.KClass

internal fun __klsx_jsonEncode(value: Any?, pretty: Boolean): String =
    error("intrinsic kotlinx.serialization.json.__klsx_jsonEncode not installed")

internal fun __klsx_jsonDecode(string: String, kClass: Any?): Any? =
    error("intrinsic kotlinx.serialization.json.__klsx_jsonDecode not installed")

public open class Json internal constructor(
    public val prettyPrint: Boolean,
    public val ignoreUnknownKeys: Boolean,
    public val encodeDefaults: Boolean,
    public val isLenient: Boolean,
    public val explicitNulls: Boolean,
    public val coerceInputValues: Boolean,
) {
    public companion object Default : Json(false, false, false, false, true, false)
}

// Top-level extensions, not members: klio binds a `reified` type
// parameter for top-level / extension functions (lowered to free
// functions) but not for inline class members, so `T::class` only
// resolves here.
public inline fun <reified T> Json.encodeToString(value: T): String =
    __klsx_jsonEncode(value, prettyPrint)

public inline fun <reified T> Json.decodeFromString(string: String): T {
    @Suppress("UNCHECKED_CAST")
    return __klsx_jsonDecode(string, T::class) as T
}

public class JsonBuilder internal constructor(from: Json) {
    public var prettyPrint: Boolean = from.prettyPrint
    public var ignoreUnknownKeys: Boolean = from.ignoreUnknownKeys
    public var encodeDefaults: Boolean = from.encodeDefaults
    public var isLenient: Boolean = from.isLenient
    public var explicitNulls: Boolean = from.explicitNulls
    public var coerceInputValues: Boolean = from.coerceInputValues
    public var prettyPrintIndent: String = "    "
    public var classDiscriminator: String = "type"

    internal fun build(): Json =
        Json(prettyPrint, ignoreUnknownKeys, encodeDefaults, isLenient, explicitNulls, coerceInputValues)
}

public fun Json(from: Json = Json.Default, builderAction: JsonBuilder.() -> Unit): Json {
    val builder = JsonBuilder(from)
    builder.builderAction()
    return builder.build()
}
