import kotlinx.datetime.*

fun t(name: String, f: () -> Any?) {
    try { println("$name -> ok " + f()) } catch (e: Throwable) { println("$name -> " + e::class.simpleName) }
}
fun main() {
    val maxYM = LocalDate.MAX.yearMonth
    val minYM = LocalDate.MIN.yearMonth
    println("max=$maxYM min=$minYM")
    t("max+(-1,MONTH)") { maxYM.plus(-1, DateTimeUnit.MONTH) }
    t("min+(1,MONTH)") { minYM.plus(1, DateTimeUnit.MONTH) }
    t("max+MAXV,YEAR") { maxYM.plus(Long.MAX_VALUE, DateTimeUnit.YEAR) }
    t("max+MAXV-2,YEAR") { maxYM.plus(Long.MAX_VALUE - 2, DateTimeUnit.YEAR) }
    t("min+MINV,YEAR") { minYM.plus(Long.MIN_VALUE, DateTimeUnit.YEAR) }
    t("min+MINV+2,YEAR") { minYM.plus(Long.MIN_VALUE + 2, DateTimeUnit.YEAR) }
    t("min+MAXV,MONTH") { minYM.plus(Long.MAX_VALUE, DateTimeUnit.MONTH) }
    t("max+MINV,MONTH") { maxYM.plus(Long.MIN_VALUE, DateTimeUnit.MONTH) }
    t("max+1,YEAR") { maxYM.plus(1, DateTimeUnit.YEAR) }
    t("min+(-1),YEAR") { minYM.plus(-1, DateTimeUnit.YEAR) }
}
