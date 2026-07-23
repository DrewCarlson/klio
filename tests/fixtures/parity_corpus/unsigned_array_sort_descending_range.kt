fun main() {
    for (size in 0..7) {
        val values = (-2 until size - 2).map { it.toULong() }.toULongArray()
        for (fromIndex in 0 until size) {
            for (toIndex in fromIndex..size) {
                val expected = values.toList().toMutableList()
                expected.subList(fromIndex, toIndex).sortDescending()
                values.sortDescending(fromIndex, toIndex)
                if (values.toList() != expected) {
                    println("$size:$fromIndex:$toIndex expected=$expected actual=${values.toList()}")
                    return
                }
            }
        }
    }
    println("OK")
}
