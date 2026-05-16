//! Native bindings for `kotlinx.io`.
//!
//! `Buffer`, `Source`, `Sink`, and `ByteString` are implemented as
//! real common-side Kotlin in the pack's `shim/` source — no native
//! state, no method-body overrides. The only `actual`s the host
//! supplies are the platform-optimised base64 / hex codecs, declared
//! `expect fun` on the Kotlin side. This keeps the pack faithful to
//! upstream's "common code + thin platform actuals" structure.

use std::rc::Rc;

use klio_runtime::{CallCtx, PrimitiveArrayKind, RuntimeError, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        // `actual` implementations of the `expect` codec extensions.
        "kotlinx.io.encodeBase64" => base64_encode,
        "kotlinx.io.decodeBase64" => base64_decode,
        "kotlinx.io.encodeHex"    => hex_encode,
        "kotlinx.io.decodeHex"    => hex_decode,
    }
}

fn arg_string(ctx: &CallCtx, idx: usize) -> Result<String, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::String(s)) => Ok(s.as_str().to_string()),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.io: argument {idx} must be a String"
        ))),
    }
}

fn arg_bytes(ctx: &CallCtx, idx: usize) -> Result<Vec<u8>, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::String(s)) => Ok(s.as_bytes().to_vec()),
        Some(Value::Array { items, .. }) => Ok(items
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Byte(b) => *b as u8,
                Value::Int(i) => (*i as i8) as u8,
                Value::Long(l) => (*l as i8) as u8,
                _ => 0,
            })
            .collect()),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.io: argument {idx} must be a String or byte array"
        ))),
    }
}

fn base64_encode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use base64::Engine;
    let data = arg_bytes(ctx, 0)?;
    let s = base64::engine::general_purpose::STANDARD.encode(&data);
    Ok(Value::String(Rc::new(s)))
}

fn base64_decode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use base64::Engine;
    let s = arg_string(ctx, 0)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes())
        .map_err(|e| RuntimeError::Type(format!("base64 decode: {e}")))?;
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(
            bytes.into_iter().map(|b| Value::Byte(b as i8)).collect(),
        ),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}

fn hex_encode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let data = arg_bytes(ctx, 0)?;
    let mut out = String::with_capacity(data.len() * 2);
    for b in data {
        out.push_str(&format!("{b:02x}"));
    }
    Ok(Value::String(Rc::new(out)))
}

fn hex_decode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = arg_string(ctx, 0)?;
    if s.len() % 2 != 0 {
        return Err(RuntimeError::Type("hex string has odd length".into()));
    }
    let mut bytes = Vec::with_capacity(s.len() / 2);
    let chars: Vec<char> = s.chars().collect();
    for pair in chars.chunks(2) {
        let hi = pair[0]
            .to_digit(16)
            .ok_or_else(|| RuntimeError::Type(format!("hex: invalid digit `{}`", pair[0])))?;
        let lo = pair[1]
            .to_digit(16)
            .ok_or_else(|| RuntimeError::Type(format!("hex: invalid digit `{}`", pair[1])))?;
        bytes.push(((hi << 4) | lo) as u8);
    }
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(
            bytes.into_iter().map(|b| Value::Byte(b as i8)).collect(),
        ),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}
