fun main() {
    val listOfLists: List<List<String>> = listOf(listOf("s"))
    val elementList: List<String> = listOf("a")
    println(listOfLists.plus(elementList))
    println(listOfLists + elementList)
    second()
}
fun second() {
    val listOfLists: List<List<String>> = listOf(listOf("s"))
    val elementList: List<String> = listOf("a")
    println(listOfLists.plusElement(elementList))
}
