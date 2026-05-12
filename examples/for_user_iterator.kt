class Words(val text: String)

class WordIter(val text: String) {
    var pos: Int = 0
    operator fun hasNext(): Boolean = pos < text.length
    operator fun next(): String {
        while (pos < text.length && text[pos] == ' ') {
            pos += 1
        }
        val start = pos
        while (pos < text.length && text[pos] != ' ') {
            pos += 1
        }
        return text.substring(start, pos)
    }
}

operator fun Words.iterator(): WordIter = WordIter(text)

fun main() {
    for (w in Words("the quick brown fox")) {
        println(w)
    }
}
