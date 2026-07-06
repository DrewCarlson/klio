# kotlinx.io

The `kotlinx.io` pack ships upstream kotlinx-io 0.9.1's common
sources, consumed directly from the in-pack git submodule: the
segment-based `Buffer`, the `Source` / `Sink` / `RawSource` /
`RawSink` hierarchy with their extension surfaces, UTF-8 codecs, and
the `ByteString` module (`ByteString`, `ByteStringBuilder`).
klio-authored actuals under `klioMain` supply the platform layer.

## Surface

```kotlin
import kotlinx.io.Buffer
import kotlinx.io.Source
import kotlinx.io.readString
import kotlinx.io.bytestring.encodeToByteString

fun main() {
    val b = Buffer()
    b.writeInt(42)
    b.writeLong(1_000_000_000_000L)
    b.writeString("kt")

    println("int=${b.readInt()}")
    println("long=${b.readLong()}")

    val s: Source = b            // a Buffer is a Source (and a Sink)
    println("string=${s.readString()}")
    println("size=${b.size}")

    val snap = "hello".encodeToByteString()
    println("encoded.size=${snap.size}")
    println("decoded=${snap.decodeToString()}")
}
```

Because the surface is the real upstream common code, the upstream
semantics apply: `Buffer` is a FIFO of segments implementing both
`Source` and `Sink`, `size` is a property, reads consume, `peek()`
gives a non-consuming `Source`, and the primitive read/write
extensions (`writeByte` … `writeDouble`, string and byte-array
codecs) are available. The ktor pack builds its channel layer on
this pack.

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-io
./zig-out/bin/klio pack install target/packs/kotlinx.io.klio-pack
```

## Out of scope (for now)

- The filesystem source set beyond the common declarations
  (`files/FileSystem.kt` / `files/Paths.kt` are included as parsed
  surface; platform file IO is not wired).
- kotlinx-io's platform-specific source sets and tests.
