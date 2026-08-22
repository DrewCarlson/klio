// Char ranges iterate as counted register loops: literal `'a'..'z'`,
// `downTo`, `until`, and a hoisted CharRange all avoid the iterator
// protocol; a stepped char progression keeps it and must agree.
fun main() {
    var sum = 0
    for (c in 'a'..'z') sum += c.code
    println("codes=$sum")

    var desc = ""
    for (c in 'x' downTo 'u') desc += c
    println("desc=$desc")

    var half = ""
    for (c in 'c' until 'f') half += c
    println("half=$half")

    var empty = 0
    for (c in 'z'..'a') empty++
    println("empty=$empty")

    val hoisted = 'A'..'E'
    var caps = ""
    for (c in hoisted) caps += c
    println("caps=$caps")

    var stepped = ""
    for (c in 'a'..'i' step 2) stepped += c
    println("stepped=$stepped")

    var top = 0
    for (c in '�'..'￿') top++
    println("top=$top")
}
