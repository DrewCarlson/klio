//! Upstream ktor `io.ktor.http` value types consumed verbatim, driven
//! through the real shipping path (build + install the ktor pack, run with
//! the `klio` binary). Exercises `ContentDisposition.parse` /
//! `withParameter`, `ContentType.parse` + `toString`, and `parseHeaderValue`
//! over multi-parameter header strings — the header/content-type layer whose
//! consumption depends on two interpreter fixes:
//!
//!  - a trailing-lambda call (`parse(value) { v, p -> … }`) binding the 2-arg
//!    inline `HeaderValueWithParameters.parse` rather than the 1-arg member
//!    (which would drop the lambda and recurse), and
//!  - `HeaderValueWithParameters.toString()`'s `apply { … parameters … }`
//!    block reading the enclosing `this.parameters` property, not the
//!    same-file top-level `fun parameters(builder)`.

use std::path::{Path, PathBuf};
use std::process::Command;

fn ws_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .expect("workspace root")
}

fn klio_bin() -> PathBuf {
    ws_root().join("target/release/klio")
}

/// Build + install the ktor pack exactly once per test process. Tests in
/// this file run on parallel threads; building/installing the pack to a
/// shared path concurrently corrupts the install (`pack hash mismatch`), so
/// gate it behind a `Once`.
fn install_ktor_pack() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let bin = klio_bin();
        assert!(
            bin.exists(),
            "target/release/klio missing — run `cargo build -p klio-cli --release` first"
        );
        // ktor-http's real runtime deps: `Codecs` URL encoding drains a
        // `kotlinx.io` `Buffer` (which needs `atomicfu`). `Url` is
        // `@Serializable`, but its `UrlSerializer` object initializes lazily
        // (on first serialization), so a plain parse/encode program does not
        // need the serialization stack.
        for crate_dir in [
            "klio-kotlinx-atomicfu",
            "klio-kotlinx-coroutines",
            "klio-kotlinx-io",
            "klio-ktor-client",
        ] {
            let dir = ws_root().join("crates").join(crate_dir);
            let out = std::env::temp_dir().join(format!("{crate_dir}.klio-pack"));
            let b = Command::new(&bin)
                .args(["pack", "build"])
                .arg(&dir)
                .arg("--out")
                .arg(&out)
                .output()
                .expect("spawn klio pack build");
            assert!(
                b.status.success(),
                "pack build {crate_dir} failed: {}",
                String::from_utf8_lossy(&b.stderr)
            );
            let i = Command::new(&bin)
                .args(["pack", "install"])
                .arg(&out)
                .output()
                .expect("spawn klio pack install");
            assert!(
                i.status.success(),
                "pack install {crate_dir} failed: {}",
                String::from_utf8_lossy(&i.stderr)
            );
        }
    });
}

fn run(file: &Path) -> String {
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(file)
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout).expect("utf8 stdout")
}

fn run_feature(file: &Path, feature: &str) -> String {
    let o = Command::new(klio_bin())
        .arg("run")
        .arg("--feature")
        .arg(feature)
        .arg(file)
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout).expect("utf8 stdout")
}

#[test]
fn ktor_request_builder_from_upstream() {
    install_ktor_pack();

    // Cores stage-3 (the swap), under the `client-upstream` feature: the real
    // upstream `HttpRequestBuilder` (url: URLBuilder, headers: HeadersBuilder,
    // body: OutgoingContent) and its immutable `HttpRequestData` — replacing
    // the simplified `shim/client` `HttpRequestBuilder` (url: String). Required
    // a parser fix for annotations on property accessors (`@InternalAPI set`).
    let src = r#"
import io.ktor.client.request.*
import io.ktor.http.*

fun main() {
    val b = HttpRequestBuilder()
    b.method = HttpMethod.Post
    b.url.takeFrom("http://localhost:8080/api?x=1")
    b.headers.append("Accept", "application/json")
    val data = b.build()
    println("${data.method.value}|${data.url}|${data.headers["Accept"]}")
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_request_builder");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run_feature(&file, "io.ktor/client-upstream");
    assert_eq!(
        got,
        "POST|http://localhost:8080/api?x=1|application/json\n",
        "ktor upstream HttpRequestBuilder output drifted"
    );
}

#[test]
fn ktor_request_pipeline_from_upstream() {
    install_ktor_pack();

    // The upstream client request/response pipelines (the `HttpClient.execute`
    // spine) consumed into `client-upstream`: `HttpRequestPipeline` /
    // `HttpResponsePipeline` (Pipeline subclasses over the real
    // `HttpRequestBuilder`), executing through `DebugPipelineContext`.
    let src = r#"
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.util.pipeline.*
import kotlinx.coroutines.*

fun main() = runBlocking {
    val rq = HttpRequestPipeline()
    val rp = HttpResponsePipeline()
    println("${HttpRequestPipeline.Before.name}|${HttpRequestPipeline.Send.name}|${HttpResponsePipeline.Parse.name}")

    val builder = HttpRequestBuilder()
    rq.intercept(HttpRequestPipeline.Render) { proceedWith(subject.toString() + "!") }
    println(rq.execute(builder, "payload"))
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_request_pipeline");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run_feature(&file, "io.ktor/client-upstream");
    assert_eq!(
        got,
        "Before|Send|Parse\n\
         payload!\n",
        "ktor upstream request pipeline output drifted"
    );
}

#[test]
fn ktor_date_and_empty_content_from_upstream() {
    install_ktor_pack();

    // Cores stage-1 foundation: `io.ktor.util.date.GMTDate` (request/response
    // timestamps) with klio's UTC calendar-math actuals, and the request-body
    // default `io.ktor.client.utils.EmptyContent` (an `OutgoingContent`).
    let src = r#"
import io.ktor.util.date.*
import io.ktor.client.utils.*
import io.ktor.client.engine.*
import io.ktor.http.content.*

fun show(d: GMTDate) {
    println("${d.year}-${d.month}-${d.dayOfMonth}|${d.hours}:${d.minutes}:${d.seconds}|${d.dayOfWeek}|${d.dayOfYear}")
}

fun main() {
    show(GMTDate(0L))
    show(GMTDate(1609459200000L))
    val d = GMTDate(30, 15, 12, 25, Month.DECEMBER, 2020)
    show(d)
    println(GMTDate(d.timestamp).timestamp == d.timestamp)

    val e: OutgoingContent = EmptyContent
    println("${e.contentLength}|${e.isEmpty()}|${e is OutgoingContent.NoContent}")

    val cfg = HttpClientEngineConfig()
    cfg.pipelining = true
    println("${cfg.pipelining}|${cfg.proxy}")
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_date_content");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "1970-JANUARY-1|0:0:0|THURSDAY|0\n\
         2021-JANUARY-1|0:0:0|FRIDAY|0\n\
         2020-DECEMBER-25|12:15:30|FRIDAY|359\n\
         true\n\
         0|true|true\n\
         true|null\n",
        "ktor date / EmptyContent output drifted"
    );
}

#[test]
fn ktor_channel_read_from_upstream() {
    install_ktor_pack();

    // The `io.ktor.utils.io` channel read path consumed from upstream: the
    // fully-buffered `SourceByteReadChannel` plus the
    // `ByteReadChannel(bytes/text)` factories and `readRemaining()` /
    // `readByteArray()` — the shape a response body is drained with. (The
    // async `ByteChannel` write side, which needs coroutine-suspension
    // fidelity, is a later lift.)
    let src = r#"
import io.ktor.utils.io.*
import kotlinx.coroutines.*

fun main() = runBlocking {
    val text = String(ByteReadChannel("hello world").readRemaining().readByteArray())
    println(text)
    val nums = ByteReadChannel(byteArrayOf(1, 2, 3, 4, 5)).readRemaining().readByteArray()
    println("${nums.size}|${nums.joinToString(",")}")
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_channel_read");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "hello world\n\
         5|1,2,3,4,5\n",
        "ktor channel read output drifted"
    );
}

#[test]
fn ktor_content_types_from_upstream() {
    install_ktor_pack();

    // The `io.ktor.http.content` body layer consumed from upstream:
    // `OutgoingContent` (sealed) + `TextContent` / `ByteArrayContent`
    // (concrete subclasses of the nested `OutgoingContent.ByteArrayContent`).
    // Exercises the content type / length / bytes, the `OutgoingContent`
    // extension `isEmpty()`, and `is`-checks against both the sealed root and
    // the nested variant — the latter needing the qualified-nested-supertype
    // resolution (a top-level `ByteArrayContent` extending the same-named
    // nested class).
    let src = r#"
import io.ktor.http.*
import io.ktor.http.content.*

fun main() {
    val t = TextContent("hello world", ContentType.Text.Plain)
    println("${t.text}|${t.contentType}|${t.contentLength}|${t.bytes().size}")

    val b = ByteArrayContent(byteArrayOf(1, 2, 3, 4), ContentType.Application.OctetStream)
    println("${b.contentLength}|${b.bytes().size}|${b.contentType}")

    val c: OutgoingContent = t
    println("${c.isEmpty()}|${t is OutgoingContent}|${b is OutgoingContent.ByteArrayContent}")
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_content");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "hello world|text/plain|11|11\n\
         4|4|application/octet-stream\n\
         false|true|true\n",
        "ktor content-type output drifted"
    );
}

#[test]
fn ktor_header_value_types_from_upstream() {
    install_ktor_pack();

    let src = r#"
import io.ktor.http.*

fun main() {
    val cd = ContentDisposition.parse("attachment; filename=\"report.pdf\"; name=upload")
    println("${cd.disposition}|${cd.name}|${cd.parameter(ContentDisposition.Parameters.FileName)}")
    println(ContentDisposition.Attachment.withParameter("filename", "a b.txt"))

    val ct = ContentType.parse("text/plain; charset=utf-8")
    println("${ct.contentType}/${ct.contentSubtype}|${ct.charset()}")
    println(ContentType("application", "json", listOf(HeaderValueParam("q", "0.5"))))

    val parts = parseHeaderValue("a/b; q=0.8; level=1, c/d")
    println("${parts.size}|${parts[0].value}|${parts[0].params.size}")

    println(" a b/c?".encodeURLParameter())
    println("a b".encodeURLParameter(spaceToPlus = true))
    println("hello world".encodeURLQueryComponent())
    println("/path/with space".encodeURLPath())
    println("%2Fp%20q".decodeURLPart())
    println("a+b%20c".decodeURLQueryComponent(plusIsSpace = true))
    println("caf%C3%A9".decodeURLPart())
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_http_value_types");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "attachment|upload|report.pdf\n\
         attachment; filename=\"a b.txt\"\n\
         text/plain|UTF-8\n\
         application/json; q=0.5\n\
         2|a/b|2\n\
         %20a%20b%2Fc%3F\n\
         a+b\n\
         hello%20world\n\
         /path/with%20space\n\
         /p q\n\
         a b c\n\
         café\n",
        "ktor header value-type output drifted"
    );
}

#[test]
fn ktor_url_parsing_from_upstream() {
    install_ktor_pack();

    // `Url` / `URLBuilder` / `URLParser` / `URLProtocol` / `Query` consumed
    // verbatim from upstream commonMain (klio supplies only the posix
    // `URLBuilder.Companion.origin` actual). Parsing resolves protocol, host,
    // port, encoded path, encoded query (case-insensitive `Parameters`), and
    // fragment across URL shapes.
    let src = r#"
import io.ktor.http.*

fun line(s: String) {
    val u = Url(s)
    println("${u.protocol.name}|${u.host}|${u.port}|${u.encodedPath}|${u.encodedQuery}|${u.fragment}")
}

fun main() {
    line("http://localhost:8080/path?q=1")
    line("https://example.com/a/b?x=1&y=2#frag")
    line("https://example.com")
    line("ws://10.0.0.1/socket")
    val u = Url("https://host/p?a=1&b=2&a=3")
    println(u.parameters.getAll("a"))
    println(u.parameters["b"])
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_url_parsing");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "http|localhost|8080|/path|q=1|\n\
         https|example.com|443|/a/b|x=1&y=2|frag\n\
         https|example.com|443|||\n\
         ws|10.0.0.1|80|/socket||\n\
         [1, 3]\n\
         2\n",
        "ktor URL parsing output drifted"
    );
}

#[test]
fn ktor_pipeline_from_upstream() {
    install_ktor_pack();

    // The `io.ktor.util.pipeline` runtime (`Pipeline`, `PipelinePhase`,
    // `PipelineContext`, `DebugPipelineContext`, `PhaseContent`) consumed
    // verbatim from upstream commonMain — the execution spine of both the
    // client and server cores. klio supplies the `DISABLE_SFG = true` actual
    // so execution runs through `DebugPipelineContext`'s proceed loop.
    // Exercises phase-ordered interception, `proceedWith` subject rewriting,
    // and multiple interceptors in one phase across two pipelines.
    let src = r#"
import io.ktor.util.pipeline.*
import kotlinx.coroutines.*

val Setup = PipelinePhase("Setup")
val Transform = PipelinePhase("Transform")

class StringPipeline : Pipeline<String, Unit>(Setup, Transform)

fun main() = runBlocking {
    val p = StringPipeline()
    p.intercept(Setup) { proceedWith("[" + subject) }
    p.intercept(Transform) { proceedWith(subject + "]") }
    p.intercept(Transform) { proceedWith(subject + "!") }
    println(p.execute(Unit, "core"))

    val q = StringPipeline()
    q.intercept(Setup) { proceedWith(subject.uppercase()) }
    println(q.execute(Unit, "abc"))
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_pipeline");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "[core]!\n\
         ABC\n",
        "ktor Pipeline execution output drifted"
    );
}

#[test]
fn ktor_attributes_from_upstream() {
    install_ktor_pack();

    // `Attributes` / `AttributeKey` consumed from upstream `Attributes.kt`
    // (+ `reflect/Type.kt` and the posix reflect actual); klio supplies the
    // platform `Attributes(concurrent)` factory. Exercises put/get/contains,
    // the `[]` set operator, `computeIfAbsent`, and remove across two keys of
    // different value types (regression for the erased `as T` cast).
    let src = r#"
import io.ktor.util.*

fun main() {
    val a = Attributes()
    val name = AttributeKey<String>("name")
    val count = AttributeKey<Int>("count")
    a.put(name, "ktor")
    a[count] = 7
    println("${a[name]}|${a[count]}|${name in a}|${a.allKeys.size}")
    println(a.computeIfAbsent(count) { 99 })
    println(a.computeIfAbsent(AttributeKey<String>("lang")) { "kotlin" })
    a.remove(name)
    println("${name in a}|${a.getOrNull(name)}")
}
"#;

    let dir = std::env::temp_dir().join("klio_ktor_attributes");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    std::fs::write(&file, src).unwrap();

    let got = run(&file);
    assert_eq!(
        got,
        "ktor|7|true|2\n\
         7\n\
         kotlin\n\
         false|null\n",
        "ktor Attributes output drifted"
    );
}
