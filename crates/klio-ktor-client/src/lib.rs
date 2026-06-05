//! Native HTTP engine for klio's ktor-client pack.
//!
//! The Kotlin shim declares `HttpClient`, `HttpRequestBuilder`,
//! `HttpResponse`, and the common `HttpMethod` surface. The engine
//! helpers `__kktor_request` / `__kktor_get` / `__kktor_post` are
//! bound here against [`ureq`], a small blocking HTTP client crate
//! that keeps the dependency footprint modest and avoids pulling a
//! full async runtime into klio's single-threaded interpreter.
//!
//! Each request returns a flat `Array<String>` shaped like
//! `[statusCode, body, contentType, headerKey, headerVal, ...]` so
//! the shim can rebuild a `HttpResponse` without the native side
//! having to construct Kotlin instances.

use std::sync::Arc;

use klio_runtime::{CallCtx, PrimitiveArrayKind, RuntimeError, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "io.ktor.client.engine.__kktor_request"   => request,
        "io.ktor.client.engine.__kktor_get"       => get,
        "io.ktor.client.engine.__kktor_post"      => post,
        "io.ktor.client.engine.__kktor_setHeader" => set_header,
        // Server engine: bind a socket and dispatch each request back
        // into the interpreter's routing lambda.
        "io.ktor.server.engine.__kktor_serve"     => serve,
        // Platform clock for `io.ktor.util.date` (the posix actual reads it
        // via cinterop; klio supplies the wall-clock epoch millis).
        "io.ktor.util.date.getTimeMillis"         => get_time_millis,
    }
}

fn get_time_millis(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    #[allow(clippy::cast_possible_wrap)]
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Ok(Value::Long(millis))
}

fn arg_string(ctx: &CallCtx, idx: usize) -> Result<String, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::String(s)) => Ok(s.as_str().to_string()),
        _ => Err(RuntimeError::Type(format!(
            "ktor-client: argument {idx} must be a String"
        ))),
    }
}

fn arg_string_array(ctx: &CallCtx, idx: usize) -> Result<Vec<String>, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::Array { items, .. }) => {
            let mut out = Vec::with_capacity(items.borrow().len());
            for v in items.borrow().iter() {
                match v {
                    Value::String(s) => out.push(s.as_str().to_string()),
                    _ => out.push(String::new()),
                }
            }
            Ok(out)
        }
        _ => Err(RuntimeError::Type(format!(
            "ktor-client: argument {idx} must be Array<String>"
        ))),
    }
}

fn make_string_array(values: Vec<String>) -> Value {
    let items: Vec<Value> = values
        .into_iter()
        .map(|s| Value::String(Arc::new(s)))
        .collect();
    Value::Array {
        items: klio_runtime::ObjRef::new(items),
        prim: None,
    }
}

fn perform(method: &str, url: &str, body: &str, headers: &[String]) -> Vec<String> {
    // Extract per-request config from reserved header keys before
    // they hit the agent. `__klio_cfg_*` keys are stripped; the
    // remainder are forwarded verbatim.
    let mut timeout_ms: u64 = 60_000;
    let mut tls_insecure: bool = false;
    let mut connect_timeout_ms: Option<u64> = None;
    let mut user_headers: Vec<String> = Vec::new();
    let mut hi = headers.iter();
    while let (Some(k), Some(v)) = (hi.next(), hi.next()) {
        match k.as_str() {
            "__klio_cfg_timeout_ms" => {
                timeout_ms = v.parse().unwrap_or(timeout_ms);
            }
            "__klio_cfg_connect_timeout_ms" => {
                connect_timeout_ms = v.parse().ok();
            }
            "__klio_cfg_tls_insecure" => {
                tls_insecure = v == "true";
            }
            _ => {
                user_headers.push(k.clone());
                user_headers.push(v.clone());
            }
        }
    }
    let mut builder =
        ureq::AgentBuilder::new().timeout(std::time::Duration::from_millis(timeout_ms));
    if let Some(ms) = connect_timeout_ms {
        builder = builder.timeout_connect(std::time::Duration::from_millis(ms));
    }
    if tls_insecure {
        // ureq's `tls_connector` slot accepts any rustls / native-tls
        // ClientConfig. Building a permissive rustls config from
        // scratch requires the danger API and a custom verifier;
        // ureq's "tls" feature wires rustls-platform-verifier by
        // default. Surface the request explicitly so users know it
        // was honored.
        eprintln!(
            "warning: __klio_cfg_tls_insecure requested; insecure mode is a no-op until a custom rustls verifier is wired"
        );
    }
    let agent = builder.build();
    let mut req = agent.request(method, url);
    let mut hi = user_headers.iter();
    while let (Some(k), Some(v)) = (hi.next(), hi.next()) {
        req = req.set(k, v);
    }
    let resp_result =
        if method == "GET" || method == "HEAD" || method == "DELETE" || body.is_empty() {
            req.call()
        } else {
            req.send_string(body)
        };
    match resp_result {
        Ok(resp) => {
            let status = resp.status();
            let content_type = resp.content_type().to_string();
            let header_pairs: Vec<(String, String)> = resp
                .headers_names()
                .iter()
                .filter_map(|n| resp.header(n).map(|v| (n.clone(), v.to_string())))
                .collect();
            let body_text = resp.into_string().unwrap_or_default();
            let mut out = vec![status.to_string(), body_text, content_type];
            for (k, v) in header_pairs {
                out.push(k);
                out.push(v);
            }
            out
        }
        Err(ureq::Error::Status(status, resp)) => {
            let content_type = resp.content_type().to_string();
            let header_pairs: Vec<(String, String)> = resp
                .headers_names()
                .iter()
                .filter_map(|n| resp.header(n).map(|v| (n.clone(), v.to_string())))
                .collect();
            let body_text = resp.into_string().unwrap_or_default();
            let mut out = vec![status.to_string(), body_text, content_type];
            for (k, v) in header_pairs {
                out.push(k);
                out.push(v);
            }
            out
        }
        Err(e) => vec!["0".into(), format!("transport error: {e}"), String::new()],
    }
}

fn request(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let method = arg_string(ctx, 0)?;
    let url = arg_string(ctx, 1)?;
    let body = arg_string(ctx, 2)?;
    let headers = arg_string_array(ctx, 3)?;
    // Permanent, env-gated HTTP trace (`KLIO_TRACE_HTTP=1`): logs each
    // outbound request to stderr. Useful for confirming whether a client
    // call actually reached the engine's transport layer.
    if std::env::var("KLIO_TRACE_HTTP").is_ok() {
        eprintln!("[HTTP] {method} {url}");
    }
    Ok(make_string_array(perform(&method, &url, &body, &headers)))
}

fn get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let url = arg_string(ctx, 0)?;
    Ok(make_string_array(perform("GET", &url, "", &[])))
}

fn post(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let url = arg_string(ctx, 0)?;
    let body = arg_string(ctx, 1)?;
    Ok(make_string_array(perform("POST", &url, &body, &[])))
}

// Signature is fixed by the `host_bindings!` registration table.
#[allow(clippy::unnecessary_wraps)]
fn set_header(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Unit)
}

// ----- Server engine -----

/// Read one HTTP/1.1 request off `stream`: returns `(method, path, body)`.
/// Headers other than `Content-Length` are skipped; the body is read to
/// the declared length. Returns `None` on a closed / malformed stream.
fn read_request(stream: &mut std::net::TcpStream) -> Option<(String, String, String)> {
    use std::io::{BufRead, BufReader, Read};
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).ok()? == 0 {
        return None;
    }
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
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
    let body = if content_length > 0 {
        let mut buf = vec![0u8; content_length];
        reader.read_exact(&mut buf).ok()?;
        String::from_utf8_lossy(&buf).into_owned()
    } else {
        String::new()
    };
    Some((method, path, body))
}

fn reason_phrase(status: i64) -> &'static str {
    match status {
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        // 200 and any unmapped code use the generic OK phrase.
        _ => "OK",
    }
}

fn write_response(stream: &mut std::net::TcpStream, status: i64, content_type: &str, body: &str) {
    use std::io::Write;
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
        reason = reason_phrase(status),
        len = body.len(),
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

/// `__kktor_serve(port, dispatch)`: bind `127.0.0.1:port` and serve
/// forever. Each request is handed to `dispatch` — a Kotlin lambda
/// `(Array<String>) -> Array<String>` taking `[method, path, body]` and
/// returning `[status, contentType, body]` — run on this thread. The
/// interpreter is single-threaded, so connections are handled
/// sequentially, which is sufficient for the blocking `start(wait=true)`
/// model.
fn serve(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let port: u16 = match ctx.args.first() {
        Some(Value::Int(p)) => u16::try_from(*p).unwrap_or(0),
        Some(Value::Long(p)) => u16::try_from(*p).unwrap_or(0),
        _ => return Err(RuntimeError::Type("__kktor_serve: port must be Int".into())),
    };
    let dispatch = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Type("__kktor_serve: missing dispatch lambda".into()))?;
    let listener = std::net::TcpListener::bind(("127.0.0.1", port))
        .map_err(|e| RuntimeError::Type(format!("__kktor_serve: bind {port} failed: {e}")))?;
    for incoming in listener.incoming() {
        let Ok(mut stream) = incoming else { continue };
        let Some((method, path, body)) = read_request(&mut stream) else {
            continue;
        };
        let req = Value::Array {
            items: klio_runtime::ObjRef::new(vec![
                Value::String(Arc::new(method)),
                Value::String(Arc::new(path)),
                Value::String(Arc::new(body)),
            ]),
            prim: None,
        };
        let out: &mut dyn klio_runtime::Output = ctx.out;
        let resp = ctx.host.invoke_callable(&dispatch, &[req], out)?;
        let (status, content_type, rbody) = decode_response(&resp);
        write_response(&mut stream, status, &content_type, &rbody);
    }
    Ok(Value::Unit)
}

/// Pull `[status, contentType, body]` out of the dispatch lambda's
/// returned `Array<String>`, with lenient fallbacks.
fn decode_response(v: &Value) -> (i64, String, String) {
    if let Value::Array { items, .. } | Value::List { items, .. } = v {
        let items = items.borrow();
        let status = match items.first() {
            Some(Value::String(s)) => s.parse().unwrap_or(200),
            Some(Value::Int(i)) => i64::from(*i),
            Some(Value::Long(l)) => *l,
            _ => 200,
        };
        let str_at = |i: usize| match items.get(i) {
            Some(Value::String(s)) => (**s).clone(),
            _ => String::new(),
        };
        return (status, str_at(1), str_at(2));
    }
    (500, "text/plain".into(), String::new())
}

// Bring `PrimitiveArrayKind` into the import group for forward-compat
// when the binding starts returning typed arrays.
#[allow(dead_code)]
fn _kind_in_scope(_: PrimitiveArrayKind) {}
