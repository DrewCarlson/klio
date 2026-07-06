# kotlinx.serialization

The `kotlinx.serialization` pack ships the serialization runtime
(1.11.0) with **no compiler plugin**. The core — annotations,
`KSerializer`, `SerialDescriptor`, the encoding contracts — is the
upstream `kotlinx-serialization-core` common source, consumed from
the in-pack submodule. Where upstream relies on plugin-generated
serializers, klio substitutes a reflective serializer: the
interpreter derives a class's serial descriptor and read/write logic
from its declaration at runtime, so `@Serializable` classes work
unmodified.

## Features

The core is always loaded with the pack. The JSON format
(`kotlinx-serialization-json`: `Json`, `encodeToString`,
`decodeFromString`) is opt-in:

```sh
klio run --feature kotlinx.serialization/json app.kt
```

## Surface

```kotlin
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString

@Serializable
data class User(val id: Int, val name: String, val tags: List<String> = emptyList())

fun main() {
    val json = Json.encodeToString(User(7, "Ada", listOf("admin")))
    println(json)                       // {"id":7,"name":"Ada","tags":["admin"]}
    val back = Json.decodeFromString<User>(json)
    println(back)                       // User(id=7, name=Ada, tags=[admin])
}
```

Nested `@Serializable` classes, collections, maps, nullable fields,
and default values round-trip. The ktor pack's `ContentNegotiation`
/ `json()` features build on this pack (its `*-serialization`
features pull `kotlinx.serialization/json` in automatically); the
kotlinx.datetime pack depends on it so its value types stay
`@Serializable`.

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-serialization
./zig-out/bin/klio pack install target/packs/kotlinx.serialization.klio-pack
```

## Layout

- Upstream core: `kotlin-klio/klio-kotlinx-serialization/upstream/`
  (submodule, curated file list in `klio.toml`)
- klio-supplied layer (reflective `serializer()`, JSON format):
  `kotlin-klio/klio-kotlinx-serialization/klioMain/`
- Native impl: `src/kotlinx_serialization/kotlinx_serialization.zig`
- Manifest: `kotlin-klio/klio-kotlinx-serialization/klio.toml`
