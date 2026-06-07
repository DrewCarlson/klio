// Default `toString` for anonymous-object instances. kotlinc-native synthesizes
// an implementation-detail class name like `main$o$1` and appends `@<hex>`; ktc
// uses a `<no name provided>@<hex>` form. Either way, structural assertions
// (contains `@`, hex tail, identity differs) hold and are byte-identical.

fun main() {
    val o = object { val x = 1 }
    val s = o.toString()
    println("hasAt=${s.indexOf('@') >= 0}")
    val tail = s.substring(s.indexOf('@') + 1)
    println("tailNonEmpty=${tail.isNotEmpty()}")

    // Explicit `toString` overrides win.
    val tagged = object {
        val n = 1
        override fun toString(): String = "tagged($n)"
    }
    println(tagged)

    // Distinct anonymous instances are distinguishable.
    val o1 = object { val x = 1 }
    val o2 = object { val x = 1 }
    println("identityDiffers=${o1.toString() != o2.toString()}")
}
