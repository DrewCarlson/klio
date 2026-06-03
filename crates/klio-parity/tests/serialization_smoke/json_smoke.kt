// JSON smoke: drives `Json.encodeToString` / `Json.decodeFromString`
// through the real klio binary, covering primitives, a nested
// @Serializable class, `List<@Serializable>`, `Map<String, @Serializable>`,
// an enum field, a nullable field, declaration-order key output, and the
// pretty-printing + ignoreUnknownKeys builder options. Expected stdout is
// the leading run of `//> ` lines.
//
//> {"name":"Al","age":30,"role":"ADMIN","addr":{"city":"NYC","zip":10001},"tags":[{"key":"a","score":1.5},{"key":"b","score":2.0}],"attrs":{"home":{"city":"LA","zip":90001}},"nick":null}
//> name=Al age=30 role=ADMIN
//> addr=NYC/10001
//> tags=a/1.5,b/2.0
//> attrs.home=LA/90001
//> nick=null
//> roundtrip=true
//> inferred=Al/NYC
//> pretty-first={
//> ignore-unknown=Pt(7, 8)

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToString
import kotlinx.serialization.json.decodeFromString

enum class Role { ADMIN, USER }

@Serializable
data class Addr(val city: String, val zip: Int)

@Serializable
data class Tag(val key: String, val score: Double)

@Serializable
data class User(
    val name: String,
    val age: Int,
    val role: Role,
    val addr: Addr,
    val tags: List<Tag>,
    val attrs: Map<String, Addr>,
    val nick: String?,
)

@Serializable
data class Pt(val x: Int, val y: Int)

fun main() {
    val u = User(
        name = "Al",
        age = 30,
        role = Role.ADMIN,
        addr = Addr("NYC", 10001),
        tags = listOf(Tag("a", 1.5), Tag("b", 2.0)),
        attrs = mapOf("home" to Addr("LA", 90001)),
        nick = null,
    )
    val s = Json.encodeToString(u)
    println(s)

    val d = Json.decodeFromString<User>(s)
    println("name=${d.name} age=${d.age} role=${d.role}")
    println("addr=${d.addr.city}/${d.addr.zip}")
    println("tags=${d.tags[0].key}/${d.tags[0].score},${d.tags[1].key}/${d.tags[1].score}")
    println("attrs.home=${d.attrs["home"]?.city}/${d.attrs["home"]?.zip}")
    println("nick=${d.nick}")
    println("roundtrip=${Json.encodeToString(d) == s}")

    // Inferred type argument: no explicit <User>, decoded from the
    // declared `val` type (the idiomatic ktor `val u: User = ...` form).
    val d2: User = Json.decodeFromString(s)
    println("inferred=${d2.name}/${d2.addr.city}")

    val pretty = Json { prettyPrint = true }
    println("pretty-first=${pretty.encodeToString(Pt(1, 2)).lines().first()}")

    val lenient = Json { ignoreUnknownKeys = true }
    val pt = lenient.decodeFromString<Pt>("{\"x\":7,\"y\":8,\"z\":9}")
    println("ignore-unknown=Pt(${pt.x}, ${pt.y})")
}
