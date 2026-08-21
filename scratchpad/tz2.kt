import kotlinx.datetime.*
fun main() {
    for (id in listOf("+04", "+04:00", "UTC+4", "UT+04", "GMT+04:00:00", "+4", "-9", "+0", "UTC+3")) {
        val z = TimeZone.of(id)
        println("$id -> id=${z.id} offset=" + (z as? FixedOffsetTimeZone)?.offset)
    }
    for (bad in listOf("UTC+", "+", "X", "+4:0", "+99")) {
        println("bad $bad -> " + try { TimeZone.of(bad).id } catch (e: Exception) { "rejected" })
    }
}
