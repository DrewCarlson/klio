import kotlin.reflect.KMutableProperty1

interface DateFields { var year: Int? }
class IncDate : DateFields { override var year: Int? = null }

class Contents(
    val date: IncDate = IncDate(),
    var tz: String? = null,
) : DateFields by date

class Plain(var tz: String? = null)

fun <O, F> probe(tag: String, p: KMutableProperty1<O, F?>, c: O, v: F) {
    p.set(c, v)
    println("$tag wrote='$v' readback='" + p.get(c) + "'")
}

fun main() {
    probe("delegating", Contents::tz, Contents(), "America/New_York")
    probe("plain     ", Plain::tz, Plain(), "America/New_York")
}
