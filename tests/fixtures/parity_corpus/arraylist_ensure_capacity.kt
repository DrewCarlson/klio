fun main() {
    val list = ArrayList<Int>()
    list.ensureCapacity(16)
    for (i in 1..3) {
        list.ensureCapacity(list.size + 1)
        list.add(i)
    }
    list.trimToSize()
    println(list)
    println(list.size)

    val viaInterface: MutableList<String> = mutableListOf()
    if (viaInterface is ArrayList) {
        viaInterface.ensureCapacity(8)
    }
    viaInterface.add("a")
    viaInterface.add("b")
    println(viaInterface)
}
