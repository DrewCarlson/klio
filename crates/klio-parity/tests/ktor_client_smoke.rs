//! ktor-client through the real shipping path: build + install the
//! ktor + kotlinx (serialization / coroutines / atomicfu) packs and run
//! a client program against a local HTTP server with the actual `klio`
//! binary. Exercises `HttpClient { install(ContentNegotiation) { json() } }`,
//! a typed `body<T>()` response decode, and a `setBody<T>()` request
//! encode round-tripped through kotlinx-serialization — the end-to-end
//! proof that serialization unblocks real ktor client modules.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
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

/// Build + install the packs the client program imports. Idempotent.
fn install_packs() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    for pack in [
        "klio-kotlinx-atomicfu",
        "klio-kotlinx-coroutines",
        "klio-kotlinx-io",
        "klio-kotlinx-serialization",
        "klio-ktor-client",
    ] {
        let dir = ws_root().join("crates").join(pack);
        let out = std::env::temp_dir().join(format!("{pack}-ktor-smoke.klio-pack"));
        let b = Command::new(&bin)
            .args(["pack", "build"])
            .arg(&dir)
            .arg("--out")
            .arg(&out)
            .output()
            .expect("spawn klio pack build");
        assert!(
            b.status.success(),
            "pack build {pack} failed: {}",
            String::from_utf8_lossy(&b.stderr)
        );
        let i = Command::new(&bin)
            .args(["pack", "install"])
            .arg(&out)
            .output()
            .expect("spawn klio pack install");
        assert!(
            i.status.success(),
            "pack install {pack} failed: {}",
            String::from_utf8_lossy(&i.stderr)
        );
    }
}

/// One-request-per-connection HTTP/1.1 server: GET returns a fixed JSON
/// user; POST echoes the request body verbatim. Serves `n` requests then
/// returns. Runs on a background thread; the bound port is returned to
/// the caller so the program URL can target it.
fn serve(n: usize) -> (u16, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let handle = std::thread::spawn(move || {
        for _ in 0..n {
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            handle_conn(stream);
        }
    });
    (port, handle)
}

fn handle_conn(mut stream: std::net::TcpStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
        return;
    }
    let is_post = request_line.starts_with("POST");
    // Read headers, capturing Content-Length.
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        let t = line.trim_end();
        if t.is_empty() {
            break;
        }
        if let Some(v) = t.to_ascii_lowercase().strip_prefix("content-length:") {
            content_length = v.trim().parse().unwrap_or(0);
        }
    }
    let body = if is_post && content_length > 0 {
        let mut buf = vec![0u8; content_length];
        reader.read_exact(&mut buf).unwrap();
        String::from_utf8_lossy(&buf).into_owned()
    } else {
        r#"{"name":"Ada","age":36,"roles":["ADMIN","USER"]}"#.to_string()
    };
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

fn run_via_binary(file: &Path) -> String {
    // The typed-body client lives in ktor's opt-in client-serialization
    // feature (mirroring ktor-client-content-negotiation +
    // ktor-serialization-kotlinx-json); enable it explicitly.
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(file)
        .args(["--feature", "io.ktor/client-serialization"])
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
fn ktor_upstream_engine_execute() {
    install_packs();
    let (port, handle) = serve(1);

    // The klio `HttpClientEngine` actual (the custom engine over the
    // `__kktor_request` host binding) consumed for the upstream client core
    // (stage 3): build an `HttpRequestData` with the upstream
    // `HttpRequestBuilder`, drive it through `engine.execute`, and drain the
    // response body off the read-side `ByteReadChannel`.
    let src = format!(
        r#"
import io.ktor.client.engine.*
import io.ktor.client.engine.klio.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.utils.io.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {{
    val engine = KlioClientEngine(KlioClientEngineConfig())
    val b = HttpRequestBuilder()
    b.method = HttpMethod.Get
    b.url.takeFrom("http://127.0.0.1:{port}/user")
    val resp = engine.execute(b.build())
    val channel = resp.body as ByteReadChannel
    val body = String(channel.readRemaining().readByteArray())
    println("${{resp.statusCode.value}}|$body")
    engine.close()
}}
"#
    );

    let dir = std::env::temp_dir().join("klio_ktor_upstream_engine");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("eng.kt");
    std::fs::write(&file, src).unwrap();
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(&file)
        .args(["--feature", "io.ktor/client-upstream"])
        .output()
        .expect("spawn klio run");
    handle.join().ok();
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    let got = String::from_utf8(o.stdout).expect("utf8 stdout");
    assert_eq!(
        got,
        "200|{\"name\":\"Ada\",\"age\":36,\"roles\":[\"ADMIN\",\"USER\"]}\n",
        "ktor upstream engine execute output drifted"
    );
}

/// Construct the upstream `HttpClient` end to end: `HttpClient(KlioClient)`
/// drives the full init — the default plugin installs through
/// `HttpClientConfig` + the `createClientPlugin` API + the klio engine
/// actual. Runs inside `runBlocking` so the factory's
/// `client.coroutineContext[Job]!!` reads the client's own context
/// (`engine.coroutineContext + clientJob`), not the ambient running
/// context — guarding the explicit-`coroutineContext` resolution fix.
/// Exercises (through real ktor code) the construction fixes:
/// enclosing-`this` chain resolution in `with(userConfig){…}`, reified
/// type-arg inference in plugin `key` initializers, the unchecked
/// `as TBuilder` cast, receiver→named-param binding when `config.install`
/// closures carry a spurious `this` capture, and invoking the
/// `createConfiguration` constructor-reference property.
#[test]
fn ktor_upstream_httpclient_constructs() {
    install_packs();
    let dir = std::env::temp_dir().join("klio_ktor_upstream_construct");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("construct.kt");
    std::fs::write(
        &file,
        r#"
import io.ktor.client.*
import io.ktor.client.engine.klio.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val client = HttpClient(KlioClient)
    println("constructed")
    client.close()
}
"#,
    )
    .unwrap();
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(&file)
        .args(["--feature", "io.ktor/client-upstream"])
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert_eq!(
        String::from_utf8(o.stdout).expect("utf8 stdout"),
        "constructed\n",
        "upstream HttpClient construction output drifted"
    );
}

#[test]
fn ktor_client_typed_bodies() {
    install_packs();
    let (port, handle) = serve(2);

    let src = format!(
        r#"
import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.call.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.Serializable
import kotlinx.coroutines.runBlocking

@Serializable
data class User(val name: String, val age: Int, val roles: List<String>)

fun main() = runBlocking {{
    val client = HttpClient {{
        install(ContentNegotiation) {{ json() }}
    }}
    val u: User = client.get("http://127.0.0.1:{port}/user").body()
    println("get=${{u.name}}/${{u.age}}/${{u.roles.joinToString(",")}}")

    val sent = User("Lin", 28, listOf("USER"))
    val back: User = client.postWith("http://127.0.0.1:{port}/echo") {{ setBody(sent) }}.body()
    println("post=${{back.name}}/${{back.age}}/${{back.roles.joinToString(",")}}")
    client.close()
}}
"#
    );

    let dir = std::env::temp_dir().join("klio_ktor_client_smoke");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("client.kt");
    std::fs::write(&file, src).unwrap();
    let got = run_via_binary(&file);
    handle.join().ok();

    assert_eq!(got, "get=Ada/36/ADMIN,USER\npost=Lin/28/USER\n");
}
