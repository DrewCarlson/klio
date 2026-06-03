//! Native bindings for `kotlinx.io`.
//!
//! `Buffer`, `Source`, `Sink`, and `ByteString` are implemented as
//! real common-side Kotlin in the pack's `shim/` source — no native
//! state, no method-body overrides. The only `actual`s the host
//! supplies are the platform-optimised base64 / hex codecs, declared
//! `expect fun` on the Kotlin side. This keeps the pack faithful to
//! upstream's "common code + thin platform actuals" structure.

use std::fmt::Write as _;
use std::sync::Arc;

use klio_runtime::{CallCtx, PrimitiveArrayKind, RuntimeError, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        // `actual` implementations of the `expect` codec extensions.
        "kotlinx.io.encodeBase64" => base64_encode,
        "kotlinx.io.decodeBase64" => base64_decode,
        "kotlinx.io.encodeHex"    => hex_encode,
        "kotlinx.io.decodeHex"    => hex_decode,
        // `kotlinx.io.files` filesystem primitives. The Kotlin actuals
        // (klioMain/kotlinx/io/files/Actuals.kt) own the policy/exception
        // logic; these are thin `std::fs` I/O primitives.
        "kotlinx.io.files.__kxio_readAllBytes"      => fs_read_all_bytes,
        "kotlinx.io.files.__kxio_writeBytes"        => fs_write_bytes,
        "kotlinx.io.files.__kxio_exists"            => fs_exists,
        "kotlinx.io.files.__kxio_delete"            => fs_delete,
        "kotlinx.io.files.__kxio_createDirectories" => fs_create_directories,
        "kotlinx.io.files.__kxio_atomicMove"        => fs_atomic_move,
        "kotlinx.io.files.__kxio_metadata"          => fs_metadata,
        "kotlinx.io.files.__kxio_resolve"           => fs_resolve,
        "kotlinx.io.files.__kxio_list"              => fs_list,
        "kotlinx.io.files.__kxio_tempDir"           => fs_temp_dir,
    }
}

fn arg_bool(ctx: &CallCtx, idx: usize) -> Result<bool, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::Bool(b)) => Ok(*b),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.io.files: argument {idx} must be a Boolean"
        ))),
    }
}

// A Kotlin `ByteArray` from raw bytes (u8 reinterpreted as signed Byte).
#[allow(clippy::cast_possible_wrap)]
fn bytes_value(bytes: Vec<u8>) -> Value {
    Value::Array {
        items: klio_runtime::ObjRef::new(bytes.into_iter().map(|b| Value::Byte(b as i8)).collect()),
        prim: Some(PrimitiveArrayKind::Byte),
    }
}

// A thrown `kotlinx.io.IOException` the Kotlin `try/catch` can catch.
fn io_error(msg: impl Into<String>) -> RuntimeError {
    RuntimeError::Thrown(Value::Exception {
        fqn: Arc::new("kotlinx.io.IOException".to_string()),
        message: Some(Arc::new(msg.into())),
        cause: None,
    })
}

fn fs_read_all_bytes(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    let bytes = std::fs::read(&path).map_err(|e| io_error(format!("read {path}: {e}")))?;
    Ok(bytes_value(bytes))
}

fn fs_write_bytes(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use std::io::Write as _;
    let path = arg_string(ctx, 0)?;
    let data = arg_bytes(ctx, 1)?;
    let append = arg_bool(ctx, 2)?;
    let mut opts = std::fs::OpenOptions::new();
    opts.create(true).write(true);
    if append {
        opts.append(true);
    } else {
        opts.truncate(true);
    }
    let mut f = opts
        .open(&path)
        .map_err(|e| io_error(format!("open {path} for write: {e}")))?;
    f.write_all(&data)
        .map_err(|e| io_error(format!("write {path}: {e}")))?;
    Ok(Value::Unit)
}

fn fs_exists(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    Ok(Value::Bool(std::path::Path::new(&path).exists()))
}

fn fs_delete(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    let p = std::path::Path::new(&path);
    let res = if p.is_dir() {
        std::fs::remove_dir(p)
    } else {
        std::fs::remove_file(p)
    };
    Ok(Value::Bool(res.is_ok()))
}

// 0 = created, 1 = already a directory, 2 = exists as a file, 3 = failed.
fn fs_create_directories(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    let p = std::path::Path::new(&path);
    if p.is_file() {
        return Ok(Value::new_int(2));
    }
    if p.is_dir() {
        return Ok(Value::new_int(1));
    }
    Ok(Value::new_int(if std::fs::create_dir_all(p).is_ok() {
        0
    } else {
        3
    }))
}

fn fs_atomic_move(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let src = arg_string(ctx, 0)?;
    let dst = arg_string(ctx, 1)?;
    Ok(Value::Bool(std::fs::rename(&src, &dst).is_ok()))
}

// `[kind, size]`: kind 0 = absent, 1 = regular file, 2 = directory.
// size is the file length for a regular file, else -1.
#[allow(clippy::cast_possible_wrap)]
fn fs_metadata(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    let (kind, size): (i64, i64) = match std::fs::metadata(&path) {
        Ok(m) if m.is_dir() => (2, -1),
        Ok(m) => (1, m.len() as i64),
        Err(_) => (0, -1),
    };
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(vec![Value::Long(kind), Value::Long(size)]),
        prim: Some(PrimitiveArrayKind::Long),
    })
}

fn fs_resolve(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    let canon =
        std::fs::canonicalize(&path).map_err(|e| io_error(format!("resolve {path}: {e}")))?;
    Ok(Value::String(Arc::new(
        canon.to_string_lossy().into_owned(),
    )))
}

fn fs_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let path = arg_string(ctx, 0)?;
    let rd = std::fs::read_dir(&path).map_err(|e| io_error(format!("list {path}: {e}")))?;
    let mut names: Vec<Value> = Vec::new();
    for entry in rd.flatten() {
        names.push(Value::String(Arc::new(
            entry.file_name().to_string_lossy().into_owned(),
        )));
    }
    Ok(Value::List {
        items: klio_runtime::ObjRef::new(names),
        mutable: false,
        enum_class: None,
        backing: None,
    })
}

#[allow(clippy::unnecessary_wraps)]
fn fs_temp_dir(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::String(Arc::new(
        std::env::temp_dir().to_string_lossy().into_owned(),
    )))
}

fn arg_string(ctx: &CallCtx, idx: usize) -> Result<String, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::String(s)) => Ok(s.as_str().to_string()),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.io: argument {idx} must be a String"
        ))),
    }
}

// Kotlin Byte is a signed i8; raw bytes reinterpret it as u8, and an
// Int/Long element narrows via toByte() before that reinterpret.
#[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
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
    Ok(Value::String(Arc::new(s)))
}

fn base64_decode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use base64::Engine;
    let s = arg_string(ctx, 0)?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(s.as_bytes())
        .map_err(|e| RuntimeError::Type(format!("base64 decode: {e}")))?;
    // Raw u8 reinterpreted as Kotlin's signed Byte.
    #[allow(clippy::cast_possible_wrap)]
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(bytes.into_iter().map(|b| Value::Byte(b as i8)).collect()),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}

fn hex_encode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let data = arg_bytes(ctx, 0)?;
    let mut out = String::with_capacity(data.len() * 2);
    for b in data {
        write!(out, "{b:02x}").unwrap();
    }
    Ok(Value::String(Arc::new(out)))
}

// Each nibble is a 4-bit hex digit, so the packed byte fits u8; the raw
// u8 then reinterprets as Kotlin's signed Byte.
#[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
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
        items: klio_runtime::ObjRef::new(bytes.into_iter().map(|b| Value::Byte(b as i8)).collect()),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}
