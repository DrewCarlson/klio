# kotlinx.io

The `kotlinx.io` pack provides a `Buffer` modelled after
upstream's FIFO byte queue. Bytes are stored in a `VecDeque<u8>`
attached to each `Buffer` instance through `InstanceData::native_state`,
which keeps both `pushBack` and `popFront` amortised O(1).

## Surface

```kotlin
import kotlinx.io.Buffer
import kotlinx.io.encodeToByteString

fun main() {
    val b = Buffer()
    b.writeInt(42)
    b.writeLong(1_000_000_000_000L)
    b.writeString("kt")

    println("size=${b.size()}")
    println("int=${b.readInt()}")
    println("long=${b.readLong()}")
    println("string=${b.readString()}")

    val snap = "hello".encodeToByteString()
    println("encoded.size=${snap.size}")
    println("decoded=${snap.decodeToString()}")
}
```

Available operations:

| Group     | Methods                                                          |
|-----------|------------------------------------------------------------------|
| Sizing    | `size()`, `isEmpty()`, `isNotEmpty()`, `clear()`                  |
| Write     | `writeByte`, `writeShort`, `writeInt`, `writeLong`, `writeString` |
| Read      | `readByte`, `readShort`, `readInt`, `readLong`, `readString`      |
| Snapshot  | `snapshot()` returns a `ByteString` copy                          |
| Pipe      | `copyTo(sink: Buffer)`                                            |

Top-level:

- `String.encodeToByteString(): ByteString`
- `ByteString.decodeToString(): String`

## Install

```sh
cargo run -q -p klio-cli -- pack build crates/klio-kotlinx-io
cargo run -q -p klio-cli -- pack install target/packs/kotlinx.io.klio-pack
```

## Out of scope (for now)

- `Source` / `Sink` interfaces.
- Async pipelining (klio is single-threaded).
- Codec support beyond `String` (UTF-8) and big-endian primitives.
