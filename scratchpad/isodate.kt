import kotlinx.datetime.*
fun main() {
    for (v in listOf("2019-10-01", "0999-12-31", "-0001-01-02", "9999-12-31", "-9999-12-31",
                     "+10000-01-01", "-10000-01-01", "+123456-01-01", "-123456-01-01")) {
        val d = LocalDate.parse(v)
        println("$v -> $d roundtrip=" + (d.toString() == v))
    }
    println("padded = " + LocalDate.parse("+" + "0".repeat(30) + "2024-01-01"))
    for (v in listOf("102017-10-01", "2017--10-01", "2017-+10-01", "2017-10-+01", "2017-10--01",
                     "2017-00-01", "2017-13-01", "2017-9-00", "2017-10-00", "2017-10-32",
                     "2017-10-01T00:00", "2021-02-29", "+1000000000-10-01")) {
        println("invalid $v -> " + (LocalDate.parseOrNull(v) == null))
    }
}
