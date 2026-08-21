import kotlinx.datetime.*
import kotlinx.datetime.internal.*

fun main() {
    val ruleString = "AST4ADT,M3.2.0,M11.1.0\n"
    val recurring = PosixTzString.readIfPresent(BinaryDataReader(ruleString.encodeToByteArray()))!!.toRecurringZoneRules()!!
    val rules = TimeZoneRulesCommon(UtcOffset(hours = -4), recurring)
    println("built")
    val infoStart = rules.infoAtDatetime(LocalDateTime(2020, 3, 8, 2, 1))
    println("start = $infoStart")
    val infoEnd = rules.infoAtDatetime(LocalDateTime(2020, 11, 1, 1, 1))
    println("end = $infoEnd")
}
