//! ktor server through the real shipping path: build + install the ktor
//! + kotlinx packs and run an `embeddedServer { … }` program with the
//! actual `klio` binary as a child process, then drive it with a tiny
//! HTTP client. Exercises routing, a typed `respond` (JSON encode), a
//! `receive<T>()` request decode, and a 404 for an unmatched route — the
//! end-to-end proof that serialization unblocks real ktor server modules.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

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

fn install_packs() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    for pack in [
        "klio-kotlinx-atomicfu",
        "klio-kotlinx-coroutines",
        "klio-kotlinx-serialization",
        "klio-ktor-client",
    ] {
        let dir = ws_root().join("crates").join(pack);
        let out = std::env::temp_dir().join(format!("{pack}-ktor-server-smoke.klio-pack"));
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

/// Grab a currently-free localhost port by binding to `:0` and releasing
/// it. A small TOCTOU window exists before the server rebinds; acceptable
/// for a smoke test.
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Minimal HTTP/1.1 client: send `method path` (+ optional body), read the
/// whole response, return `(status_code, body)`.
fn http(port: u16, method: &str, path: &str, body: Option<&str>) -> (u16, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n");
    if let Some(b) = body {
        req.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            b.len()
        ));
    }
    req.push_str("\r\n");
    if let Some(b) = body {
        req.push_str(b);
    }
    stream.write_all(req.as_bytes()).unwrap();
    stream.flush().unwrap();
    let mut raw = String::new();
    stream.read_to_string(&mut raw).unwrap();
    let status = raw
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse().ok())
        .unwrap_or(0);
    let body = raw.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    (status, body)
}

fn wait_for_port(port: u16) -> bool {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    false
}

#[test]
fn ktor_server_routes_and_typed_bodies() {
    install_packs();
    let port = free_port();

    let src = format!(
        r#"
import io.ktor.server.engine.*
import io.ktor.server.cio.*
import io.ktor.server.application.*
import io.ktor.server.routing.*
import io.ktor.server.response.*
import io.ktor.server.request.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.Serializable

@Serializable
data class User(val name: String, val age: Int, val roles: List<String>)

fun main() {{
    embeddedServer(CIO, port = {port}) {{
        install(ContentNegotiation) {{ json() }}
        routing {{
            get("/user") {{
                call.respond(User("Ada", 36, listOf("ADMIN", "USER")))
            }}
            post("/echo") {{
                val u: User = call.receive()
                call.respond(u.copy(age = u.age + 1))
            }}
        }}
    }}.start(wait = true)
}}
"#
    );

    let dir = std::env::temp_dir().join("klio_ktor_server_smoke");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("server.kt");
    std::fs::write(&file, src).unwrap();

    let mut child = Command::new(klio_bin())
        .arg("run")
        .arg(&file)
        .spawn()
        .expect("spawn klio server");

    let ready = wait_for_port(port);
    let result = std::panic::catch_unwind(|| {
        assert!(ready, "server did not start listening on {port}");
        let (gs, gb) = http(port, "GET", "/user", None);
        assert_eq!(gs, 200, "GET /user status");
        assert_eq!(gb, r#"{"name":"Ada","age":36,"roles":["ADMIN","USER"]}"#);
        let (ps, pb) = http(
            port,
            "POST",
            "/echo",
            Some(r#"{"name":"Lin","age":28,"roles":["USER"]}"#),
        );
        assert_eq!(ps, 200, "POST /echo status");
        assert_eq!(pb, r#"{"name":"Lin","age":29,"roles":["USER"]}"#);
        let (ms, _) = http(port, "GET", "/missing", None);
        assert_eq!(ms, 404, "GET /missing status");
    });

    let _ = child.kill();
    let _ = child.wait();
    result.expect("ktor server assertions failed");
}
