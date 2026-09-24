// The kotlinx-datetime value types are `@Serializable` through the serializers
// the library names: dates and times as ISO strings, periods in ISO 8601
// duration form, a DateTimeUnit polymorphically by its kind, and a date as its
// components when a property picks the component serializer.
//
// Run with: klio run --feature kotlinx.serialization/json examples/datetime_serializers.kt

import kotlinx.datetime.DatePeriod
import kotlinx.datetime.DateTimePeriod
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.LocalTime
import kotlinx.datetime.serializers.LocalDateComponentSerializer
import kotlinx.datetime.serializers.LocalDateIso8601Serializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

@Serializable
data class Meeting(
    val day: LocalDate,
    val at: LocalTime,
    val start: LocalDateTime,
    @Serializable(with = LocalDateComponentSerializer::class) val parts: LocalDate,
)

@Serializable
data class Plan(val every: DatePeriod, val unit: DateTimeUnit, val span: DateTimePeriod)

fun main() {
    val meeting = Meeting(
        LocalDate(2024, 3, 1),
        LocalTime(9, 30),
        LocalDateTime(2024, 3, 1, 9, 30, 15),
        LocalDate(2021, 12, 9),
    )
    val m = Json.encodeToString(meeting)
    println(m)
    println(Json.decodeFromString<Meeting>(m) == meeting)

    val plan = Plan(DatePeriod(years = 1, months = 2, days = 3), DateTimeUnit.MONTH, DateTimePeriod(hours = 5))
    val p = Json.encodeToString(plan)
    println(p)
    println(Json.decodeFromString<Plan>(p))

    println(Json.encodeToString(LocalDateIso8601Serializer, LocalDate(2020, 1, 4)))
}
