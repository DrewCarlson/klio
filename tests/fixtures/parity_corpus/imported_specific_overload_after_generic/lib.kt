package cells

class Cell<T>(val label: String)
class IntCell(val label: String)

fun <T> cell(value: T): Cell<T> = Cell("generic")
fun cell(value: Int): IntCell = IntCell("int")
