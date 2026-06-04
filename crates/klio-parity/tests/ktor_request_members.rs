//! ktor-client request members (Batch 9.3) through the real shipping
//! path: `put`/`delete`/`patch`, `parameter`, and `bearerAuth` driven by
//! the actual `klio` binary against a local echo server that reflects the
//! request method, path, and Authorization header.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
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

fn install_ktor() {
    let bin = klio_bin();
    assert!(bin.exists(), "build the release binary first");
    let dir = ws_root().join("crates/klio-ktor-client");
    let out = std::env::temp_dir().join("ktor-reqmembers.klio-pack");
    let b = Command::new(&bin)
        .args(["pack", "build"])
        .arg(&dir)
        .arg("--out")
        .arg(&out)
        .output()
        .expect("pack build");
    assert!(b.status.success(), "build: {}", String::from_utf8_lossy(&b.stderr));
    let i = Command::new(&bin).args(["pack", "install"]).arg(&out).output().expect("install");
    assert!(i.status.success(), "install: {}", String::from_utf8_lossy(&i.stderr));
}

/// Echo server: replies `METHOD PATH auth=AUTH`. Serves `n` requests.
fn serve(n: usize) -> (u16, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let h = std::thread::spawn(move || {
        for _ in 0..n {
            let Ok(mut stream) = listener.accept().map(|(s, _)| s) else { return };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                continue;
            }
            let mut parts = line.split_whitespace();
            let method = parts.next().unwrap_or("").to_string();
            let path = parts.next().unwrap_or("").to_string();
            let mut auth = "none".to_string();
            let mut clen = 0usize;
            loop {
                let mut hl = String::new();
                if reader.read_line(&mut hl).unwrap_or(0) == 0 {
                    break;
                }
                let t = hl.trim_end();
                if t.is_empty() {
                    break;
                }
                let low = t.to_ascii_lowercase();
                if low.starts_with("authorization:") {
                    auth = t[t.find(':').map_or(0, |i| i + 1)..].trim().to_string();
                } else if let Some(v) = low.strip_prefix("content-length:") {
                    clen = v.trim().parse().unwrap_or(0);
                }
            }
            if clen > 0 {
                let mut buf = vec![0u8; clen];
                use std::io::Read;
                let _ = reader.read_exact(&mut buf);
            }
            let body = format!("{method} {path} auth={auth}");
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });
    (port, h)
}

#[test]
fn ktor_client_request_members() {
    install_ktor();
    let (port, handle) = serve(4);
    let src = format!(
        r#"
import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import kotlinx.coroutines.runBlocking
fun main() = runBlocking {{
    val c = HttpClient()
    println(c.putWith("http://127.0.0.1:{port}/p") {{ parameter("a", "1"); bearerAuth("tok") }}.bodyAsText())
    println(c.delete("http://127.0.0.1:{port}/d").bodyAsText())
    println(c.patch("http://127.0.0.1:{port}/x", "body").bodyAsText())
    println(c.putWith("http://127.0.0.1:{port}/b") {{ basicAuth("aladdin", "opensesame") }}.bodyAsText())
    c.close()
}}
"#
    );
    let dir = std::env::temp_dir().join("klio_ktor_reqmembers");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("req.kt");
    std::fs::write(&file, src).unwrap();
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(&file)
        .args(["--feature", "io.ktor/client"])
        .output()
        .expect("klio run");
    handle.join().ok();
    let out = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success(), "stderr: {}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(
        out,
        "PUT /p?a=1 auth=Bearer tok\nDELETE /d auth=none\nPATCH /x auth=none\n\
         PUT /b auth=Basic YWxhZGRpbjpvcGVuc2VzYW1l\n"
    );
}
