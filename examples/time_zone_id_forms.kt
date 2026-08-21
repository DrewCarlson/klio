// `TimeZone.of` accepts an IANA region id, the UTC aliases, and every written
// form of a fixed offset — `+4`, `+04`, `+04:00`, `+0400`, and the same with a
// `UTC`/`GMT`/`UT` prefix. Zones that share an offset stay distinguishable by
// id, because the id keeps the prefix it was written with.
//
// Run with: klio run examples/time_zone_id_forms.kt

import kotlinx.datetime.FixedOffsetTimeZone
import kotlinx.datetime.TimeZone
import kotlinx.datetime.UtcOffset

fun main() {
    val sameOffset = listOf("+4", "+04", "+04:00", "+0400", "UTC+4", "UT+04", "GMT+04:00:00")
    for (id in sameOffset) {
        val z = TimeZone.of(id)
        println("$id -> id=${z.id} offset=${(z as FixedOffsetTimeZone).offset}")
    }
    // One offset, several ids.
    val zones = sameOffset.map { TimeZone.of(it) }
    println("offsets distinct = " + zones.map { (it as FixedOffsetTimeZone).offset }.distinct().size)
    println("ids distinct     = " + zones.map { it.id }.distinct().size)

    // A zero offset collapses to the ISO `Z`, and the bare names keep theirs.
    println("+0  -> " + TimeZone.of("+0").id)
    println("UTC -> " + TimeZone.of("UTC").id)
    println("GMT -> " + TimeZone.of("GMT").id)

    // Parsing the same offset twice yields the same instance: an offset is a
    // value, and the zero offset is `UtcOffset.ZERO` however it was written.
    println("Z is ZERO    = " + (UtcOffset.parse("Z") === UtcOffset.ZERO))
    println("+00:00 ZERO  = " + (UtcOffset.parse("+00:00") === UtcOffset.ZERO))
    println("-00:00:00    = " + (UtcOffset.parse("-00:00:00") === UtcOffset.ZERO))
    println("+04:00 twice = " + (UtcOffset.parse("+04:00") === UtcOffset.parse("+04:00")))

    // A region id is not a fixed offset.
    val paris = TimeZone.of("Europe/Paris")
    println("region fixed = " + (paris is FixedOffsetTimeZone) + " id=" + paris.id)

    // Malformed ids are rejected.
    for (bad in listOf("UTC+", "+", "X", "+4:0", "+99", "Nowhere/Nowhere")) {
        val ok = try { TimeZone.of(bad); true } catch (e: Exception) { false }
        println("accepts $bad = $ok")
    }
}
