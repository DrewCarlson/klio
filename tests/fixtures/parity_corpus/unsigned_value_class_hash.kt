// An unsigned value class synthesizes hashCode from its SIGNED storage
// (UShort.data: Short), so 65535u hashes as -1 — the magnitude hash made
// List<UShort>.hashCode disagree with UShortArray.contentHashCode (which
// delegates to the signed storage array) once the latter ran its real body.
fun main() {
    println(65535.toUShort().hashCode())
    println(255.toUByte().hashCode())
    val a = ushortArrayOf(1u, 65535u, 0u)
    println(a.toList().hashCode())
    println(a.contentHashCode())
    val b = ubyteArrayOf(1u, 255u, 0u)
    println(b.toList().hashCode())
    println(b.contentHashCode())
}
