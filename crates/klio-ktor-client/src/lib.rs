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
    }
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

// Bring `PrimitiveArrayKind` into the import group for forward-compat
// when the binding starts returning typed arrays.
#[allow(dead_code)]
fn _kind_in_scope(_: PrimitiveArrayKind) {}
