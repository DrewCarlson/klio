// ktor's own test server, for the client census suites: the service in
// src/itests/commontest_support.zig runs this with
// `klio run --feature io.ktor/test-server`, as upstream's Gradle build starts
// the server before its client test runs.

import io.ktor.testserver.runTestServer

fun main() {
    runTestServer()
}
