// klio actuals for the two `expect`s declared in kotlinx-io's own common test
// sources (`core/common/test/util.kt`). Without them every test that touches a
// temp file, and every UTF-8 round-trip test, fails to resolve.
//
// klio reports itself as the Native platform, so these mirror
// `core/native/test`'s actuals rather than the JVM ones.

package kotlinx.io

import kotlinx.io.files.SystemTemporaryDirectory

// A distinct name per call. The upstream tests create the file themselves and
// delete it afterwards, so this only has to be unique, not pre-created.
private var tempFileCounter = 0

actual fun tempFileName(): String {
    tempFileCounter += 1
    val dir = SystemTemporaryDirectory.toString()
    val sep = if (dir.endsWith("/")) "" else "/"
    return dir + sep + "klio-io-test-" + tempFileCounter + "-" + randomSuffix()
}

private fun randomSuffix(): String {
    // Cheap, dependency-free spread: mix the counter through a couple of
    // rounds so concurrent files in one run do not collide.
    var h = tempFileCounter * 2654435761L
    h = h xor (h ushr 13)
    h *= 1274126177L
    h = h xor (h ushr 16)
    val v = if (h < 0) -h else h
    return v.toString(16)
}

// kotlinx-io's OWN encoder, not the stdlib's. `encodeToByteArray()` replaces
// malformed input with U+FFFD, and these tests deliberately feed lone
// surrogates and expect the library's byte-for-byte behaviour — with the
// stdlib encoder a one-byte expectation came back as the three bytes of the
// replacement character. Native and JS mirror this same choice.
internal actual fun String.asUtf8ToByteArray(): ByteArray = commonAsUtf8ToByteArray()
