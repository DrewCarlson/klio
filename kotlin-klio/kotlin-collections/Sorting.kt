package kotlin.collections

// The JVM sorts objects with TimSort, `Arrays.sort` with a comparator and over
// `Comparable` elements in their natural order alike: natural runs, found left to
// right and lengthened to a minimum run by binary insertion, are kept on a stack
// whose lengths shrink fast toward its top, the top runs merging whenever they
// would not; a merge gallops while one run keeps winning. A comparator here sees
// the same pairs in the same order as there, so one that counts or logs its calls
// prints what the JVM's does, and one that contradicts itself fails the same way.
// The comparisons are Kotlin calls, which run at the speed of the rest of the
// program; an order klio compares itself over values it compares itself (numbers,
// characters, strings, Booleans), whose comparisons nothing observes, sorts in
// the host (`__klio_sortNatively`).

/**
 * Sorts `a[fromIndex until toIndex]` in place in the host and answers true when [comparator]
 * is the natural order (null too) or its reverse and every element there is a number, a
 * character, a string or a Boolean of one kind; false, the array untouched, otherwise.
 */
private fun __klio_sortNatively(a: Array<*>, fromIndex: Int, toIndex: Int, comparator: Comparator<*>?): Boolean =
    error("intrinsic kotlin.collections.__klio_sortNatively not installed")

/** The JVM's `Arrays.rangeCheck`. */
private fun sortRangeCheck(size: Int, fromIndex: Int, toIndex: Int) {
    if (fromIndex > toIndex) throw IllegalArgumentException("fromIndex($fromIndex) > toIndex($toIndex)")
    if (fromIndex < 0) throw klio.ArrayIndexOutOfBoundsException("Array index out of range: $fromIndex")
    if (toIndex > size) throw klio.ArrayIndexOutOfBoundsException("Array index out of range: $toIndex")
}

public actual fun <T> Array<out T>.sortWith(comparator: Comparator<in T>): Unit {
    @Suppress("UNCHECKED_CAST")
    if (size > 1 && !__klio_sortNatively(this, 0, size, comparator)) timSort(this as Array<T>, 0, size, comparator)
}

public actual fun <T> Array<out T>.sortWith(comparator: Comparator<in T>, fromIndex: Int, toIndex: Int): Unit {
    sortRangeCheck(size, fromIndex, toIndex)
    @Suppress("UNCHECKED_CAST")
    if (!__klio_sortNatively(this, fromIndex, toIndex, comparator)) timSort(this as Array<T>, fromIndex, toIndex, comparator)
}

public actual fun <T : Comparable<T>> Array<out T>.sort(): Unit {
    @Suppress("UNCHECKED_CAST")
    if (size > 1 && !__klio_sortNatively(this, 0, size, null)) timSort(this as Array<T>, 0, size, naturalOrder())
}

public actual fun <T : Comparable<T>> Array<out T>.sort(fromIndex: Int, toIndex: Int): Unit {
    sortRangeCheck(size, fromIndex, toIndex)
    @Suppress("UNCHECKED_CAST")
    if (!__klio_sortNatively(this, fromIndex, toIndex, null)) timSort(this as Array<T>, fromIndex, toIndex, naturalOrder())
}

private const val MIN_MERGE = 32
private const val MIN_GALLOP = 7
private const val CONTRACT_VIOLATION = "Comparison method violates its general contract!"

/** Sorts `a[fromIndex until toIndex]` stably by [comparator], as the JVM's `Arrays.sort` does. */
private fun <T> timSort(a: Array<T>, fromIndex: Int, toIndex: Int, comparator: Comparator<in T>) {
    var lo = fromIndex
    var remaining = toIndex - fromIndex
    if (remaining < 2) return
    if (remaining < MIN_MERGE) {
        val run = ascendingRun(a, lo, toIndex, comparator)
        binaryInsertionSort(a, lo, toIndex, lo + run, comparator)
        return
    }
    val merger = RunMerger(a, comparator)
    val minRun = minRunLength(remaining)
    do {
        var run = ascendingRun(a, lo, toIndex, comparator)
        if (run < minRun) {
            val forced = if (remaining <= minRun) remaining else minRun
            binaryInsertionSort(a, lo, lo + forced, lo + run, comparator)
            run = forced
        }
        merger.push(lo, run)
        merger.collapse()
        lo += run
        remaining -= run
    } while (remaining != 0)
    merger.collapseAll()
}

/**
 * The length of the run starting at [lo]: the longest ascending one, or the longest
 * strictly descending one, which is reversed in place so every run ascends.
 */
private fun <T> ascendingRun(a: Array<T>, lo: Int, hi: Int, c: Comparator<in T>): Int {
    var end = lo + 1
    if (end == hi) return 1
    if (c.compare(a[end++], a[lo]) < 0) {
        while (end < hi && c.compare(a[end], a[end - 1]) < 0) end++
        var i = lo
        var j = end - 1
        while (i < j) {
            val t = a[i]
            a[i++] = a[j]
            a[j--] = t
        }
    } else {
        while (end < hi && c.compare(a[end], a[end - 1]) >= 0) end++
    }
    return end - lo
}

/** Sorts `a[lo until hi]`, whose elements before [sorted] are in order, by binary insertion. */
private fun <T> binaryInsertionSort(a: Array<T>, lo: Int, hi: Int, sorted: Int, c: Comparator<in T>) {
    var next = if (sorted == lo) sorted + 1 else sorted
    while (next < hi) {
        val pivot = a[next]
        var left = lo
        var right = next
        while (left < right) {
            val mid = (left + right) ushr 1
            if (c.compare(pivot, a[mid]) < 0) right = mid else left = mid + 1
        }
        // The elements from `left` move up a place, as the JVM's `binarySort` moves them.
        when (val n = next - left) {
            2 -> {
                a[left + 2] = a[left + 1]
                a[left + 1] = a[left]
            }
            1 -> a[left + 1] = a[left]
            else -> a.copyInto(a, left + 1, left, left + n)
        }
        a[left] = pivot
        next++
    }
}

/** The shortest run a sort of [n] elements makes before merging: n kept below 32, rounded up while halved. */
private fun minRunLength(n: Int): Int {
    var m = n
    var odd = 0
    while (m >= MIN_MERGE) {
        odd = odd or (m and 1)
        m = m shr 1
    }
    return m + odd
}

/**
 * Where [key] goes among `a[base until base + len]`, ascending, before any element equal to it,
 * searched outward from `base + hint` by doubling steps and then by halving.
 */
private fun <T> gallopLeft(key: T, a: Array<T>, base: Int, len: Int, hint: Int, c: Comparator<in T>): Int {
    var lastOfs = 0
    var ofs = 1
    if (c.compare(key, a[base + hint]) > 0) {
        val maxOfs = len - hint
        while (ofs < maxOfs && c.compare(key, a[base + hint + ofs]) > 0) {
            lastOfs = ofs
            ofs = (ofs shl 1) + 1
            if (ofs <= 0) ofs = maxOfs
        }
        if (ofs > maxOfs) ofs = maxOfs
        lastOfs += hint
        ofs += hint
    } else {
        val maxOfs = hint + 1
        while (ofs < maxOfs && c.compare(key, a[base + hint - ofs]) <= 0) {
            lastOfs = ofs
            ofs = (ofs shl 1) + 1
            if (ofs <= 0) ofs = maxOfs
        }
        if (ofs > maxOfs) ofs = maxOfs
        val t = lastOfs
        lastOfs = hint - ofs
        ofs = hint - t
    }
    lastOfs++
    while (lastOfs < ofs) {
        val m = lastOfs + ((ofs - lastOfs) ushr 1)
        if (c.compare(key, a[base + m]) > 0) lastOfs = m + 1 else ofs = m
    }
    return ofs
}

/** As [gallopLeft], but after every element equal to [key]. */
private fun <T> gallopRight(key: T, a: Array<T>, base: Int, len: Int, hint: Int, c: Comparator<in T>): Int {
    var lastOfs = 0
    var ofs = 1
    if (c.compare(key, a[base + hint]) < 0) {
        val maxOfs = hint + 1
        while (ofs < maxOfs && c.compare(key, a[base + hint - ofs]) < 0) {
            lastOfs = ofs
            ofs = (ofs shl 1) + 1
            if (ofs <= 0) ofs = maxOfs
        }
        if (ofs > maxOfs) ofs = maxOfs
        val t = lastOfs
        lastOfs = hint - ofs
        ofs = hint - t
    } else {
        val maxOfs = len - hint
        while (ofs < maxOfs && c.compare(key, a[base + hint + ofs]) >= 0) {
            lastOfs = ofs
            ofs = (ofs shl 1) + 1
            if (ofs <= 0) ofs = maxOfs
        }
        if (ofs > maxOfs) ofs = maxOfs
        lastOfs += hint
        ofs += hint
    }
    lastOfs++
    while (lastOfs < ofs) {
        val m = lastOfs + ((ofs - lastOfs) ushr 1)
        if (c.compare(key, a[base + m]) < 0) ofs = m else lastOfs = m + 1
    }
    return ofs
}

/** The runs a sort has found and not yet merged, and what its merges share. */
private class RunMerger<T>(private val a: Array<T>, private val c: Comparator<in T>) {
    private var minGallop = MIN_GALLOP
    private var tmp: Array<Any?> = arrayOfNulls(if (a.size < 512) a.size ushr 1 else 256)
    private val runBase = IntArray(49)
    private val runLen = IntArray(49)
    private var runs = 0

    fun push(base: Int, len: Int) {
        runBase[runs] = base
        runLen[runs] = len
        runs++
    }

    /** Merges the top runs until each run is longer than the next two together and the next one. */
    fun collapse() {
        while (runs > 1) {
            var n = runs - 2
            if (n > 0 && runLen[n - 1] <= runLen[n] + runLen[n + 1] ||
                n > 1 && runLen[n - 2] <= runLen[n] + runLen[n - 1]
            ) {
                if (runLen[n - 1] < runLen[n + 1]) n--
            } else if (runLen[n] > runLen[n + 1]) {
                break
            }
            mergeAt(n)
        }
    }

    /** Merges every run into one. */
    fun collapseAll() {
        while (runs > 1) {
            var n = runs - 2
            if (n > 0 && runLen[n - 1] < runLen[n + 1]) n--
            mergeAt(n)
        }
    }

    private fun mergeAt(i: Int) {
        var base1 = runBase[i]
        var len1 = runLen[i]
        val base2 = runBase[i + 1]
        var len2 = runLen[i + 1]
        runLen[i] = len1 + len2
        if (i == runs - 3) {
            runBase[i + 1] = runBase[i + 2]
            runLen[i + 1] = runLen[i + 2]
        }
        runs--
        // The first run's elements before the second's first are in place already,
        // and so are the second's after the first's last.
        val k = gallopRight(a[base2], a, base1, len1, 0, c)
        base1 += k
        len1 -= k
        if (len1 == 0) return
        len2 = gallopLeft(a[base1 + len1 - 1], a, base2, len2, len2 - 1, c)
        if (len2 == 0) return
        if (len1 <= len2) mergeLow(base1, len1, base2, len2) else mergeHigh(base1, len1, base2, len2)
    }

    @Suppress("UNCHECKED_CAST")
    private fun tmpFor(n: Int): Array<T> {
        if (tmp.size < n) {
            var size = n
            size = size or (size shr 1)
            size = size or (size shr 2)
            size = size or (size shr 4)
            size = size or (size shr 8)
            size = size or (size shr 16)
            size++
            tmp = arrayOfNulls(if (size < 0) n else minOf(size, a.size ushr 1))
        }
        return tmp as Array<T>
    }

    /** Merges two adjacent runs from the front, the first, no longer than the second, copied aside. */
    private fun mergeLow(base1: Int, len1In: Int, base2: Int, len2In: Int) {
        var len1 = len1In
        var len2 = len2In
        val t = tmpFor(len1)
        a.copyInto(t, 0, base1, base1 + len1)
        var cursor1 = 0
        var cursor2 = base2
        var dest = base1
        a[dest++] = a[cursor2++]
        if (--len2 == 0) {
            t.copyInto(a, dest, cursor1, cursor1 + len1)
            return
        }
        if (len1 == 1) {
            a.copyInto(a, dest, cursor2, cursor2 + len2)
            a[dest + len2] = t[cursor1]
            return
        }
        var gallop = minGallop
        outer@ while (true) {
            var count1 = 0
            var count2 = 0
            do {
                if (c.compare(a[cursor2], t[cursor1]) < 0) {
                    a[dest++] = a[cursor2++]
                    count2++
                    count1 = 0
                    if (--len2 == 0) break@outer
                } else {
                    a[dest++] = t[cursor1++]
                    count1++
                    count2 = 0
                    if (--len1 == 1) break@outer
                }
            } while ((count1 or count2) < gallop)
            do {
                count1 = gallopRight(a[cursor2], t, cursor1, len1, 0, c)
                if (count1 != 0) {
                    t.copyInto(a, dest, cursor1, cursor1 + count1)
                    dest += count1
                    cursor1 += count1
                    len1 -= count1
                    if (len1 <= 1) break@outer
                }
                a[dest++] = a[cursor2++]
                if (--len2 == 0) break@outer
                count2 = gallopLeft(t[cursor1], a, cursor2, len2, 0, c)
                if (count2 != 0) {
                    a.copyInto(a, dest, cursor2, cursor2 + count2)
                    dest += count2
                    cursor2 += count2
                    len2 -= count2
                    if (len2 == 0) break@outer
                }
                a[dest++] = t[cursor1++]
                if (--len1 == 1) break@outer
                gallop--
            } while (count1 >= MIN_GALLOP || count2 >= MIN_GALLOP)
            if (gallop < 0) gallop = 0
            gallop += 2
        }
        minGallop = if (gallop < 1) 1 else gallop
        when (len1) {
            1 -> {
                a.copyInto(a, dest, cursor2, cursor2 + len2)
                a[dest + len2] = t[cursor1]
            }
            0 -> throw IllegalArgumentException(CONTRACT_VIOLATION)
            else -> t.copyInto(a, dest, cursor1, cursor1 + len1)
        }
    }

    /** Merges two adjacent runs from the back, the second, no longer than the first, copied aside. */
    private fun mergeHigh(base1: Int, len1In: Int, base2: Int, len2In: Int) {
        var len1 = len1In
        var len2 = len2In
        val t = tmpFor(len2)
        a.copyInto(t, 0, base2, base2 + len2)
        var cursor1 = base1 + len1 - 1
        var cursor2 = len2 - 1
        var dest = base2 + len2 - 1
        a[dest--] = a[cursor1--]
        if (--len1 == 0) {
            t.copyInto(a, dest - (len2 - 1), 0, len2)
            return
        }
        if (len2 == 1) {
            dest -= len1
            cursor1 -= len1
            a.copyInto(a, dest + 1, cursor1 + 1, cursor1 + 1 + len1)
            a[dest] = t[cursor2]
            return
        }
        var gallop = minGallop
        outer@ while (true) {
            var count1 = 0
            var count2 = 0
            do {
                if (c.compare(t[cursor2], a[cursor1]) < 0) {
                    a[dest--] = a[cursor1--]
                    count1++
                    count2 = 0
                    if (--len1 == 0) break@outer
                } else {
                    a[dest--] = t[cursor2--]
                    count2++
                    count1 = 0
                    if (--len2 == 1) break@outer
                }
            } while ((count1 or count2) < gallop)
            do {
                count1 = len1 - gallopRight(t[cursor2], a, base1, len1, len1 - 1, c)
                if (count1 != 0) {
                    dest -= count1
                    cursor1 -= count1
                    len1 -= count1
                    a.copyInto(a, dest + 1, cursor1 + 1, cursor1 + 1 + count1)
                    if (len1 == 0) break@outer
                }
                a[dest--] = t[cursor2--]
                if (--len2 == 1) break@outer
                count2 = len2 - gallopLeft(a[cursor1], t, 0, len2, len2 - 1, c)
                if (count2 != 0) {
                    dest -= count2
                    cursor2 -= count2
                    len2 -= count2
                    t.copyInto(a, dest + 1, cursor2 + 1, cursor2 + 1 + count2)
                    if (len2 <= 1) break@outer
                }
                a[dest--] = a[cursor1--]
                if (--len1 == 0) break@outer
                gallop--
            } while (count1 >= MIN_GALLOP || count2 >= MIN_GALLOP)
            if (gallop < 0) gallop = 0
            gallop += 2
        }
        minGallop = if (gallop < 1) 1 else gallop
        when (len2) {
            1 -> {
                dest -= len1
                cursor1 -= len1
                a.copyInto(a, dest + 1, cursor1 + 1, cursor1 + 1 + len1)
                a[dest] = t[cursor2]
            }
            0 -> throw IllegalArgumentException(CONTRACT_VIOLATION)
            else -> t.copyInto(a, dest - (len2 - 1), 0, len2)
        }
    }
}
