/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// Upstream's JVM CallLoggingTest.kt on klio's CallLogging port. The cases and
// their assertions are upstream's; the platform types change: the test
// logger implements io.ktor.util.logging.Logger instead of delegating to an
// slf4j logger, `Level` is `LogLevel`, MDC and MDCContext are klio.logging's,
// the ANSI expectations are written as escape sequences instead of through
// jansi, and the context-switch cases switch to Dispatchers.Default and
// Dispatchers.IO instead of a java.util.concurrent executor and a new thread
// pool (klio's kotlinx.coroutines has no newSingleThreadContext or
// newFixedThreadPoolContext). klio has no static file routes, so the
// static-content case marks its call the way they do.
// TerminalTest.kt checks that jansi uninstalls its console streams and has
// no counterpart.

package io.ktor.server.plugins.calllogging

import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.config.*
import io.ktor.server.engine.*
import io.ktor.server.http.content.*
import io.ktor.server.plugins.*
import io.ktor.server.plugins.callid.*
import io.ktor.server.plugins.statuspages.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.testing.*
import io.ktor.test.*
import io.ktor.util.logging.*
import klio.logging.MDC
import klio.logging.MDCContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.test.*

@Suppress("SameParameterValue")
class CallLoggingTest {

    private lateinit var messages: MutableList<String>
    private val logger: Logger = object : Logger {
        override val level: LogLevel = LogLevel.TRACE
        override fun error(message: String) {}
        override fun error(message: String, cause: Throwable) {}
        override fun warn(message: String) {}
        override fun warn(message: String, cause: Throwable) {}
        override fun info(message: String) = add("INFO: $message")
        override fun info(message: String, cause: Throwable) {}
        override fun debug(message: String) = add("DEBUG: $message")
        override fun debug(message: String, cause: Throwable) = add("DEBUG: $message")
        override fun trace(message: String) = add("TRACE: $message")
        override fun trace(message: String, cause: Throwable) {}

        private fun add(message: String?) {
            if (message != null) {
                val mdcText = MDC.getCopyOfContextMap()?.let { mdc ->
                    if (mdc.isNotEmpty()) {
                        mdc.entries.sortedBy { it.key }
                            .joinToString(prefix = " [", postfix = "]") { "${it.key}=${it.value}" }
                    } else {
                        ""
                    }
                } ?: ""

                messages.add(message + mdcText)
            }
        }
    }
    private val environment: ApplicationEnvironmentBuilder.() -> Unit = {
        log = logger
    }

    @BeforeTest
    fun setup() {
        messages = ArrayList()
    }

    @Test
    fun `can log an unhandled get request`() = testApplication {
        environment { environment() }
        install(CallLogging) { clock { 0 } }

        createClient { expectSuccess = false }.get("/")

        assertTrue("INFO: ${red("404 Not Found")}: ${cyan("GET")} - / in 0ms" in messages)
    }

    @Test
    fun `can log a successful get request`() = testApplication {
        environment { environment() }
        install(CallLogging) { clock { 0 } }
        routing {
            get {
                call.respond(HttpStatusCode.OK)
            }
        }

        client.get("/")

        assertTrue("INFO: ${green("200 OK")}: ${cyan("GET")} - / in 0ms" in messages)
    }

    @Test
    fun `can customize message format`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                format { call ->
                    "${call.request.uri} -> ${call.response.status()}, took ${call.processingTimeMillis { 3 }}ms"
                }
                clock { 0 }
            }
            routing {
                get("/{...}") {
                    call.respondText("OK")
                }
            }
        }

        client.get("/uri-123")
        assertTrue("INFO: /uri-123 -> 200 OK, took 3ms" in messages)
    }

    @Test
    fun `logs request processing time`() = testApplication {
        var time = 123L
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                clock { time.also { time += 100 } }
            }
            routing {
                get("/{...}") {
                    call.respondText("OK")
                }
            }
        }

        client.get("/")
        assertTrue("INFO: ${green("200 OK")}: ${cyan("GET")} - / in 100ms" in messages)
    }

    @Test
    fun `can filter calls to log`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                filter { !it.request.origin.uri.contains("avoid") }
                clock { 0 }
            }
        }

        val client = createClient { expectSuccess = false }
        client.get("/")
        client.get("/avoid")

        assertTrue("INFO: ${red("404 Not Found")}: ${cyan("GET")} - / in 0ms" in messages)
        assertFalse("INFO: ${red("404 Not Found")}: ${cyan("GET")} - /avoid in 0ms" in messages)
    }

    @Test
    fun `can change log level`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                level = LogLevel.DEBUG
                clock { 0 }
            }
        }
        routing {
            get {
                call.respond(HttpStatusCode.OK)
            }
        }

        client.get("/")

        assertTrue("DEBUG: ${green("200 OK")}: ${cyan("GET")} - / in 0ms" in messages)
    }

    @Test
    fun `can fill MDC after call`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                mdc("mdc-uri") { it.request.uri }
                mdc("mdc-status") { it.response.status()?.value?.toString() }
                format { it.request.uri }
                clock { 0 }
            }
        }
        routing {
            get("/*") {
                environment.log.info("test message")
                call.respond("OK")
            }
        }

        client.get("/uri1")
        assertTrue { "INFO: test message [mdc-uri=/uri1]" in messages }
        assertTrue { "INFO: /uri1 [mdc-status=200, mdc-uri=/uri1]" in messages }
    }

    @Test
    fun `reuses provider value`() = testApplication {
        environment {
            log = logger
        }
        var counter = 0
        application {
            install(CallLogging) {
                mdc("mdc-test") { "${counter++}" }
                format { it.request.uri }
                clock { 0 }
            }
        }
        routing {
            get("/*") {
                environment.log.info("test1")
                environment.log.info("test2")
                call.respond("OK")
            }
        }

        client.get("/uri1")
        assertTrue { "INFO: test1 [mdc-test=0]" in messages }
        assertFalse { "INFO: test1 [mdc-test=1]" in messages }
    }

    @Test
    fun `can fill MDC before routing`() = testApplication {
        @Suppress("LocalVariableName")
        val TestPlugin = createApplicationPlugin("TestPlugin") {
            onCall { it.response.headers.append("test-header", "test-value") }
        }
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                mdc("mdc-test-header") { it.response.headers["test-header"] }
                mdc("mdc-status") { it.response.status()?.value?.toString() }
                format { it.request.uri }
                clock { 0 }
            }
            install(TestPlugin)
        }
        routing {
            get("/*") {
                application.log.info("test message")
                call.respond("OK")
            }
        }

        client.get("/uri1")
        assertTrue("INFO: test message [mdc-test-header=test-value]" in messages)
        assertTrue("INFO: /uri1 [mdc-status=200, mdc-test-header=test-value]" in messages)
    }

    @Test
    fun `can fill MDC and survive context switch`() = testApplication {
        var counter = 0
        val dispatcher = Dispatchers.Default

        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                mdc("mdc-uri") { it.request.uri }
                callIdMdc("mdc-call-id")
                clock { 0 }
            }
            install(CallId) {
                generate { "generated-call-id-${counter++}" }
            }
        }
        application {
            routing {
                get("/*") {
                    withContext(dispatcher) {
                        application.log.info("test message")
                    }
                    call.respond("OK")
                }
            }
        }

        client.get("/uri1")
        assertTrue { "INFO: test message [mdc-call-id=generated-call-id-0, mdc-uri=/uri1]" in messages }
        assertTrue {
            "INFO: ${green("200 OK")}: ${cyan("GET")} - " +
                "/uri1 in 0ms [mdc-call-id=generated-call-id-0, mdc-uri=/uri1]" in messages
        }
    }

    @Test
    fun `can fill MDC and survive context switch in IOCoroutineDispatcher`() = testApplication {
        var counter = 0

        val dispatcher = Dispatchers.IO
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                mdc("mdc-uri") { it.request.uri }
                callIdMdc("mdc-call-id")
                clock { 0 }
            }
            install(CallId) {
                generate { "generated-call-id-${counter++}" }
            }
        }
        application {
            routing {
                get("/*") {
                    withContext(dispatcher) {
                        application.log.info("test message")
                    }
                    call.respond("OK")
                }
            }
        }

        client.get("/uri1")
        assertTrue { "INFO: test message [mdc-call-id=generated-call-id-0, mdc-uri=/uri1]" in messages }
        assertTrue {
            "INFO: ${green("200 OK")}: ${cyan("GET")} - " +
                "/uri1 in 0ms [mdc-call-id=generated-call-id-0, mdc-uri=/uri1]" in messages
        }
    }

    @Test
    fun `will setup mdc provider and use in status pages plugin`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                mdc("mdc-uri") { it.request.uri }
                clock { 0 }
            }
            install(StatusPages) {
                exception<Throwable> { call, _ ->
                    call.application.log.info("test message")
                    call.respond("OK")
                }
            }
        }
        application {
            routing {
                get("/*") {
                    throw Exception()
                }
            }
        }

        client.get("/uri1")
        assertTrue { "INFO: test message [mdc-uri=/uri1]" in messages }
    }

    @Test
    fun `can configure custom logger`() = runTest {
        val customMessages = ArrayList<String>()
        val customLogger: Logger = object : Logger {
            override val level: LogLevel = LogLevel.TRACE
            override fun error(message: String) {}
            override fun error(message: String, cause: Throwable) {}
            override fun warn(message: String) {}
            override fun warn(message: String, cause: Throwable) {}
            override fun info(message: String) {
                customMessages.add("CUSTOM TRACE: $message")
            }
            override fun info(message: String, cause: Throwable) {}
            override fun debug(message: String) {}
            override fun debug(message: String, cause: Throwable) {}
            override fun trace(message: String) {}
            override fun trace(message: String, cause: Throwable) {}
        }

        runTestApplication {
            application {
                install(CallLogging) {
                    this.logger = customLogger
                    clock { 0 }
                }
            }
            client.get("/")
        }

        assertTrue(customMessages.isNotEmpty())
        assertTrue(customMessages.all { it.startsWith("CUSTOM TRACE:") })
        assertTrue(messages.isEmpty())
    }

    @Test
    fun `can log without colors`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                disableDefaultColors()
                clock { 0 }
            }
        }
        createClient { expectSuccess = false }.get("/")

        assertTrue("INFO: 404 Not Found: GET - / in 0ms" in messages)
    }

    @Test
    fun `mdc exception does not crash request`() = testApplication {
        var failed = 0
        install(CallLogging) {
            mdc("bar") {
                failed++
                throw Exception()
            }
            mdc("foo") { "Hello" }
        }

        routing {
            get {
                call.respond("OK")
            }
        }

        assertEquals(0, failed)

        assertEquals("OK", client.get("/").bodyAsText())
        assertEquals(3, failed)

        assertEquals("OK", client.get("/").bodyAsText())
        assertEquals(6, failed)
    }

    @Test
    fun `ignore static file request`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                level = LogLevel.INFO
                clock { 0 }
                disableDefaultColors()
                disableForStaticContent()
            }
        }
        application {
            routing {
                get("/CallLoggingTest.kt") {
                    call.attributes.put(StaticFileLocationProperty, "CallLoggingTest.kt")
                    call.respondText("static")
                }
            }
        }
        val response = client.get("/CallLoggingTest.kt")
        assertEquals(HttpStatusCode.OK, response.status)
        assertFalse("INFO: 200 OK: GET - /CallLoggingTest.kt in 0ms" in messages)
    }

    @Test
    fun logsErrorWithMdc() = testApplication {
        environment {
            log = logger
            config = MapApplicationConfig("ktor.test.throwOnException" to "false")
        }
        install(CallLogging) {
            callIdMdc()
            disableDefaultColors()
            clock { 0 }
        }
        routing {
            get("/error") {
                throw Exception("Unexpected")
            }
        }
        val response = client.get("/error")
        assertEquals(HttpStatusCode.InternalServerError, response.status)
        assertEquals("Unexpected", response.bodyAsText())
        assertContains(messages, "INFO: 500 Internal Server Error: GET - /error in 0ms")
    }

    @Test
    fun logErrorMessage() = testApplication {
        environment {
            log = logger
            config = MapApplicationConfig("ktor.test.throwOnException" to "false")
        }
        install(CallLogging) {
            level = LogLevel.DEBUG
            disableDefaultColors()
            clock { 0 }
        }
        routing {
            get("/") {
                throw BadRequestException("Message of exception")
            }
        }

        client.get("/").apply {
            assertEquals(HttpStatusCode.BadRequest, status)
            @Suppress("ktlint:standard:max-line-length")
            assertContains(
                messages,
                "DEBUG: Unhandled: GET - /. Exception class io.ktor.server.plugins.BadRequestException: Message of exception"
            )
        }
    }

    @Test
    fun `dont override MDC with configured entry`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                mdc("hardcoded") { "1" }

                format { it.request.uri }
            }
        }
        routing {
            get("/with") {
                MDC.put("name", "<name>")
                withContext(MDCContext()) {
                    call.respondText { "OK" }
                }
            }
            get("/without") {
                call.respondText { "OK" }
            }
        }

        client.get("/with")
        client.get("/without")

        assertContains(messages, "INFO: /with [hardcoded=1, name=<name>]")
        assertContains(messages, "INFO: /without [hardcoded=1]")
    }

    @Test
    fun `no double logging when with Status Pages`() = testApplication {
        environment {
            log = logger
        }
        application {
            install(CallLogging) {
                format { it.request.uri }
            }
            install(StatusPages) {
                status(HttpStatusCode.BadRequest) { call, _ ->
                    call.respond("From StatusPages")
                }
            }
        }
        routing {
            get {
                call.respond(HttpStatusCode.BadRequest)
            }
        }

        client.get("/").apply {
            assertEquals(HttpStatusCode.OK, status)
            assertEquals("From StatusPages", bodyAsText())
        }

        assertEquals(1, messages.count { it == "INFO: /" })
    }

    private fun green(value: Any): String = colored(value, 32)
    private fun red(value: Any): String = colored(value, 31)
    private fun cyan(value: Any): String = colored(value, 36)

    private fun colored(value: Any, color: Int): String = "\u001B[${color}m$value\u001B[m"
}
