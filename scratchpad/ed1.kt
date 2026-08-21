import kotlinx.datetime.*
fun main() {
    println(LocalDate(1970, 1, 1).toEpochDays())
    println(LocalDate(2000, 3, 1).toEpochDays())
    println(LocalDate(1969, 12, 31).toEpochDays())
    println(LocalDate(-1, 12, 31).toEpochDays())
    println(LocalDate(-999999, 1, 1).toEpochDays())
    println(LocalDate(999999, 12, 31).toEpochDays())
}
