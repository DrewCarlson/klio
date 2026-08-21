import kotlinx.datetime.*

fun main() {
    println("UtcOffset(0,0,0) same = " + (UtcOffset(hours = 0, minutes = 0, seconds = 0) === UtcOffset.ZERO))
    println("UtcOffset(hours=0) same = " + (UtcOffset(hours = 0) === UtcOffset.ZERO))
    println("UtcOffset(seconds=0) same = " + (UtcOffset(seconds = 0) === UtcOffset.ZERO))
    println("UtcOffset(minutes=0) same = " + (UtcOffset(minutes = 0) === UtcOffset.ZERO))
    println("parse -00:00 same = " + (UtcOffset.parse("-00:00") === UtcOffset.ZERO))
}
