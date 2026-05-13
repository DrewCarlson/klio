//! Native bindings for `kotlinx.io`.
//!
//! Buffer state is kept in a process-wide `thread_local!` map keyed
//! by the receiver `Value::Instance`'s `identity`. The Kotlin shim
//! under `shim/` declares the Buffer / ByteString surface; these
//! bindings override every read / write method with byte-vector
//! manipulation so each operation runs in O(1) amortised time.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};

use klio_runtime::{CallCtx, PrimitiveArrayKind, RuntimeError, Value};
use klio_stdlib::HostBindings;

thread_local! {
    /// Per-instance byte queue keyed by `InstanceData::identity`. The
    /// kotlinx.io Buffer is FIFO: writes append at the back, reads
    /// drain from the front. `VecDeque` gives O(1) amortised
    /// pop_front so a 1 MB write/read loop stays linear instead of
    /// quadratic. Upstream kotlinx.io uses a segmented linked list
    /// for the same reason; `VecDeque` is the cheap equivalent that
    /// satisfies the API contract until segmenting matters.
    static BUFFERS: RefCell<HashMap<u64, VecDeque<u8>>> = RefCell::new(HashMap::new());
}

fn with_buffer<R>(
    ctx: &CallCtx,
    f: impl FnOnce(&mut VecDeque<u8>) -> Result<R, RuntimeError>,
) -> Result<R, RuntimeError> {
    let id = receiver_id(ctx)?;
    BUFFERS.with(|map| {
        let mut map = map.borrow_mut();
        let buf = map.entry(id).or_default();
        f(buf)
    })
}

fn receiver_id(ctx: &CallCtx) -> Result<u64, RuntimeError> {
    match ctx.args.first() {
        Some(Value::Instance(inst)) => Ok(inst.borrow().identity),
        _ => Err(RuntimeError::Type(
            "kotlinx.io binding expected an instance receiver".into(),
        )),
    }
}

fn arg_int(ctx: &CallCtx, idx: usize) -> Result<i64, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::Int(i)) => Ok(*i as i64),
        Some(Value::Long(l)) => Ok(*l),
        Some(Value::Short(s)) => Ok(*s as i64),
        Some(Value::Byte(b)) => Ok(*b as i64),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.io: argument {idx} must be an integer"
        ))),
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

#[must_use]
pub fn host_bindings() -> HostBindings {
    let mut b = HostBindings::new();
    let bindings: &[(&'static str, klio_runtime::StdlibFn)] = &[
        ("kotlinx.io.Buffer.size", buffer_size),
        ("kotlinx.io.Buffer.isEmpty", buffer_is_empty),
        ("kotlinx.io.Buffer.isNotEmpty", buffer_is_not_empty),
        ("kotlinx.io.Buffer.clear", buffer_clear),
        ("kotlinx.io.Buffer.writeByte", buffer_write_byte),
        ("kotlinx.io.Buffer.writeInt", buffer_write_int),
        ("kotlinx.io.Buffer.writeLong", buffer_write_long),
        ("kotlinx.io.Buffer.writeShort", buffer_write_short),
        ("kotlinx.io.Buffer.writeString", buffer_write_string),
        ("kotlinx.io.Buffer.readByte", buffer_read_byte),
        ("kotlinx.io.Buffer.readInt", buffer_read_int),
        ("kotlinx.io.Buffer.readLong", buffer_read_long),
        ("kotlinx.io.Buffer.readShort", buffer_read_short),
        ("kotlinx.io.Buffer.readString", buffer_read_string),
        ("kotlinx.io.Buffer.snapshot", buffer_snapshot),
        ("kotlinx.io.Buffer.copyTo", buffer_copy_to),
        ("kotlinx.io.ByteString.decodeToString", byte_string_decode_to_string),
        ("kotlinx.io.encodeToByteString", string_encode_to_byte_string),
    ];
    for (k, f) in bindings {
        b.register(k, *f);
    }
    b
}

fn buffer_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| Ok(Value::Long(buf.len() as i64)))
}

fn buffer_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| Ok(Value::Bool(buf.is_empty())))
}

fn buffer_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| Ok(Value::Bool(!buf.is_empty())))
}

fn buffer_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| {
        buf.clear();
        Ok(Value::Unit)
    })
}

fn buffer_write_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)?;
    with_buffer(ctx, |buf| {
        buf.push_back(v as u8);
        Ok(Value::Unit)
    })
}

fn buffer_write_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)? as i32;
    with_buffer(ctx, |buf| {
        for b in v.to_be_bytes() {
            buf.push_back(b);
        }
        Ok(Value::Unit)
    })
}

fn buffer_write_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)?;
    with_buffer(ctx, |buf| {
        for b in v.to_be_bytes() {
            buf.push_back(b);
        }
        Ok(Value::Unit)
    })
}

fn buffer_write_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)? as i16;
    with_buffer(ctx, |buf| {
        for b in v.to_be_bytes() {
            buf.push_back(b);
        }
        Ok(Value::Unit)
    })
}

fn buffer_write_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = arg_string(ctx, 1)?;
    with_buffer(ctx, |buf| {
        for b in s.as_bytes() {
            buf.push_back(*b);
        }
        Ok(Value::Unit)
    })
}

fn drain_front(buf: &mut VecDeque<u8>, n: usize) -> Result<Vec<u8>, RuntimeError> {
    if buf.len() < n {
        return Err(RuntimeError::Type(format!(
            "kotlinx.io.Buffer: not enough bytes ({} available, {n} requested)",
            buf.len()
        )));
    }
    Ok(buf.drain(..n).collect())
}

fn buffer_read_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| {
        let v = drain_front(buf, 1)?;
        Ok(Value::Byte(v[0] as i8))
    })
}

fn buffer_read_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| {
        let bytes = drain_front(buf, 4)?;
        let arr: [u8; 4] = bytes.as_slice().try_into().unwrap();
        Ok(Value::new_int(i32::from_be_bytes(arr) as i64))
    })
}

fn buffer_read_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| {
        let bytes = drain_front(buf, 8)?;
        let arr: [u8; 8] = bytes.as_slice().try_into().unwrap();
        Ok(Value::Long(i64::from_be_bytes(arr)))
    })
}

fn buffer_read_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| {
        let bytes = drain_front(buf, 2)?;
        let arr: [u8; 2] = bytes.as_slice().try_into().unwrap();
        Ok(Value::Short(i16::from_be_bytes(arr)))
    })
}

fn buffer_read_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |buf| {
        // VecDeque can be split into two slices; collect to a Vec
        // before UTF-8 decoding so the borrow on `buf` clears
        // before the result is constructed.
        let bytes: Vec<u8> = buf.drain(..).collect();
        let s = String::from_utf8(bytes).map_err(|e| {
            RuntimeError::Type(format!("kotlinx.io.Buffer.readString: invalid UTF-8: {e}"))
        })?;
        Ok(Value::String(std::rc::Rc::new(s)))
    })
}

/// Materialise the buffer's current contents as a `ByteString` —
/// modelled by a `Value::Array` of bytes. The buffer is left intact;
/// `snapshot` is a copy, matching kotlinx.io's semantics.
fn buffer_snapshot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let bytes = with_buffer(ctx, |buf| Ok(buf.clone()))?;
    let items: Vec<Value> = bytes.iter().map(|b| Value::new_int(*b as i8 as i64)).collect();
    Ok(Value::Array {
        items: std::rc::Rc::new(RefCell::new(items)),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}

fn buffer_copy_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let src_id = receiver_id(ctx)?;
    let sink_id = match ctx.args.get(1) {
        Some(Value::Instance(inst)) => inst.borrow().identity,
        _ => {
            return Err(RuntimeError::Type(
                "kotlinx.io.Buffer.copyTo: sink must be a Buffer".into(),
            ))
        }
    };
    BUFFERS.with(|map| {
        let mut map = map.borrow_mut();
        let src_bytes: VecDeque<u8> = map.get(&src_id).cloned().unwrap_or_default();
        map.entry(sink_id).or_default().extend(src_bytes);
        Ok(Value::Unit)
    })
}

fn byte_string_decode_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // ByteString shim stores the byte vector inside `data` field of
    // the Value::Instance. Reach in via the `data` field on the
    // receiver instance and decode as UTF-8.
    let Some(Value::Instance(inst)) = ctx.args.first() else {
        return Err(RuntimeError::Type(
            "kotlinx.io.ByteString.decodeToString: receiver must be a ByteString".into(),
        ));
    };
    let data = inst.borrow().get("data").unwrap_or(Value::Null);
    let bytes: Vec<u8> = match data {
        Value::Array { items, .. } => items
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Int(i) => (*i as i8) as u8,
                Value::Long(l) => (*l as i8) as u8,
                _ => 0u8,
            })
            .collect(),
        _ => Vec::new(),
    };
    let s = String::from_utf8(bytes).map_err(|e| {
        RuntimeError::Type(format!(
            "kotlinx.io.ByteString.decodeToString: invalid UTF-8: {e}"
        ))
    })?;
    Ok(Value::String(std::rc::Rc::new(s)))
}

/// `String.encodeToByteString()` — top-level extension. The function
/// is exposed as a non-receiver top-level binding because klio's
/// dispatch table for extension intrinsics keys on the function FQN.
fn string_encode_to_byte_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => s.as_str().to_string(),
        _ => {
            return Err(RuntimeError::Type(
                "encodeToByteString: receiver must be a String".into(),
            ))
        }
    };
    let items: Vec<Value> = s.as_bytes().iter().map(|b| Value::new_int(*b as i8 as i64)).collect();
    // The shim's ByteString class has a `data: ByteArray` field. We
    // can't construct a Value::Instance here without access to the
    // class table — instead surface the bytes as a Value::Array so
    // user code can `.toByteArray()` / iterate; the shim layer
    // wraps it back if needed.
    Ok(Value::Array {
        items: std::rc::Rc::new(RefCell::new(items)),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}
