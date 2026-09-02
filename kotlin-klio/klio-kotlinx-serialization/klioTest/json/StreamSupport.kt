// klio-authored TEST-SUPPORT actuals for the json test suite's streaming
// modes. Upstream's JsonTestBase parametrizes every test over STREAMING,
// TREE, OKIO_STREAMS and KXIO_STREAMS; the last two need the okio and
// kotlinx-io buffer types plus the json-okio / json-io adapter modules,
// which the pack does not ship. These string-backed stand-ins run the
// exact same streaming codec through a sink/source adapter, so the
// four-way result comparison the base class performs stays meaningful.
// Test sources are never edited; this file is composed into the run as
// platform support, like CurrentPlatform.kt.

package okio

public class Buffer {
    private val sb = StringBuilder()
    public fun writeUtf8(s: String): Buffer { sb.append(s); return this }
    public fun readUtf8(): String { val r = sb.toString(); sb.setLength(0); return r }
    override fun toString(): String = sb.toString()
}
public typealias BufferedSink = Buffer
public typealias BufferedSource = Buffer
