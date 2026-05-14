//! Native bindings for `kotlinx.io`.
//!
//! Buffer state lives on the receiver `Value::Instance` itself via
//! the `InstanceData::native_state` slot. The Kotlin shim under
//! `shim/` declares the Buffer / ByteString surface; these bindings
//! override every read / write method with `VecDeque<u8>`
//! manipulation, matching the FIFO semantics of upstream
//! kotlinx.io's Buffer at O(1) amortised cost per byte.
//!
//! The state lifetime is tied to the instance: when the last
//! reference to the `Value::Instance` drops, the `NativeState` it
//! carries drops with it. No side-map cleanup, no identity-based
//! routing.

use std::cell::{RefCell, RefMut};
use std::collections::VecDeque;
use std::rc::Rc;

use klio_runtime::{CallCtx, InstanceData, PrimitiveArrayKind, RuntimeError, Value};

/// Discriminator the kotlinx.io binding uses to mark `NativeState`
/// it owns. Other host bindings on the same instance would carry a
/// different `kind` and panic when this binding tries to coerce.
const BUFFER_KIND: &str = "kotlinx.io.Buffer";

#[derive(Default)]
struct BufferState {
    bytes: VecDeque<u8>,
}

fn with_buffer<R>(
    ctx: &CallCtx,
    f: impl FnOnce(&mut BufferState) -> Result<R, RuntimeError>,
) -> Result<R, RuntimeError> {
    let cell = buffer_cell(ctx)?;
    let borrow = cell.borrow_mut();
    let mut state =
        RefMut::map(borrow, |any| any.downcast_mut::<BufferState>().expect("buffer state type"));
    f(&mut state)
}

fn buffer_cell(ctx: &CallCtx) -> Result<Rc<RefCell<dyn std::any::Any>>, RuntimeError> {
    let Some(Value::Instance(inst)) = ctx.args.first() else {
        return Err(RuntimeError::Type(
            "kotlinx.io binding expected an instance receiver".into(),
        ));
    };
    Ok(inst.borrow_mut().ensure_native_state(BUFFER_KIND, BufferState::default))
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

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "kotlinx.io.__kxio_bufferSize"         => buffer_size_helper,
        "kotlinx.io.Buffer.isEmpty"            => buffer_is_empty,
        "kotlinx.io.Buffer.isNotEmpty"         => buffer_is_not_empty,
        "kotlinx.io.Buffer.clear"              => buffer_clear,
        "kotlinx.io.Buffer.writeByte"          => buffer_write_byte,
        "kotlinx.io.Buffer.writeInt"           => buffer_write_int,
        "kotlinx.io.Buffer.writeLong"          => buffer_write_long,
        "kotlinx.io.Buffer.writeShort"         => buffer_write_short,
        "kotlinx.io.Buffer.writeString"        => buffer_write_string,
        "kotlinx.io.Buffer.readByte"           => buffer_read_byte,
        "kotlinx.io.Buffer.readInt"            => buffer_read_int,
        "kotlinx.io.Buffer.readLong"           => buffer_read_long,
        "kotlinx.io.Buffer.readShort"          => buffer_read_short,
        "kotlinx.io.Buffer.readString"         => buffer_read_string,
        "kotlinx.io.Buffer.snapshot"           => buffer_snapshot,
        "kotlinx.io.Buffer.copyTo"             => buffer_copy_to,
        "kotlinx.io.ByteString.decodeToString" => byte_string_decode_to_string,
        "kotlinx.io.encodeToByteString"        => string_encode_to_byte_string,
        "kotlinx.io.__kxio_base64Encode"       => base64_encode,
        "kotlinx.io.__kxio_base64Decode"       => base64_decode,
        "kotlinx.io.__kxio_hexEncode"          => hex_encode,
        "kotlinx.io.__kxio_hexDecode"          => hex_decode,
        "kotlinx.io.Buffer.writeVarint"        => buffer_write_varint,
        "kotlinx.io.Buffer.readVarint"         => buffer_read_varint,
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
        items: Rc::new(RefCell::new(
            bytes.into_iter().map(|b| Value::Byte(b as i8)).collect(),
        )),
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
        let hi = pair[0].to_digit(16).ok_or_else(|| {
            RuntimeError::Type(format!("hex: invalid digit `{}`", pair[0]))
        })?;
        let lo = pair[1].to_digit(16).ok_or_else(|| {
            RuntimeError::Type(format!("hex: invalid digit `{}`", pair[1]))
        })?;
        bytes.push(((hi << 4) | lo) as u8);
    }
    Ok(Value::Array {
        items: Rc::new(RefCell::new(
            bytes.into_iter().map(|b| Value::Byte(b as i8)).collect(),
        )),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}

// Protobuf-style unsigned varint encoding.
fn buffer_write_varint(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut v = arg_int(ctx, 1)? as u64;
    with_buffer(ctx, |state| {
        loop {
            let mut byte = (v & 0x7f) as u8;
            v >>= 7;
            if v != 0 {
                byte |= 0x80;
                state.bytes.push_back(byte);
            } else {
                state.bytes.push_back(byte);
                break;
            }
        }
        Ok(Value::Unit)
    })
}

fn buffer_read_varint(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let mut result: u64 = 0;
        let mut shift: u32 = 0;
        loop {
            let b = state
                .bytes
                .pop_front()
                .ok_or_else(|| RuntimeError::Type("varint: buffer empty mid-decode".into()))?;
            result |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                break;
            }
            shift += 7;
            if shift > 63 {
                return Err(RuntimeError::Type("varint too large for Long".into()));
            }
        }
        Ok(Value::Long(result as i64))
    })
}

fn buffer_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| Ok(Value::Long(state.bytes.len() as i64)))
}

// Top-level `kotlinx.io.__kxio_bufferSize(buffer)` — the shim's
// `Buffer.size` property getter calls this. Receiver-as-first-arg
// path means `args[0]` is the Buffer instance.
fn buffer_size_helper(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    buffer_size(ctx)
}

fn buffer_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| Ok(Value::Bool(state.bytes.is_empty())))
}

fn buffer_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| Ok(Value::Bool(!state.bytes.is_empty())))
}

fn buffer_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        state.bytes.clear();
        Ok(Value::Unit)
    })
}

fn buffer_write_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)?;
    with_buffer(ctx, |state| {
        state.bytes.push_back(v as u8);
        Ok(Value::Unit)
    })
}

fn buffer_write_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)? as i32;
    with_buffer(ctx, |state| {
        for b in v.to_be_bytes() {
            state.bytes.push_back(b);
        }
        Ok(Value::Unit)
    })
}

fn buffer_write_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)?;
    with_buffer(ctx, |state| {
        for b in v.to_be_bytes() {
            state.bytes.push_back(b);
        }
        Ok(Value::Unit)
    })
}

fn buffer_write_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg_int(ctx, 1)? as i16;
    with_buffer(ctx, |state| {
        for b in v.to_be_bytes() {
            state.bytes.push_back(b);
        }
        Ok(Value::Unit)
    })
}

fn buffer_write_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = arg_string(ctx, 1)?;
    with_buffer(ctx, |state| {
        for b in s.as_bytes() {
            state.bytes.push_back(*b);
        }
        Ok(Value::Unit)
    })
}

fn drain_front(state: &mut BufferState, n: usize) -> Result<Vec<u8>, RuntimeError> {
    if state.bytes.len() < n {
        return Err(RuntimeError::Type(format!(
            "kotlinx.io.Buffer: not enough bytes ({} available, {n} requested)",
            state.bytes.len()
        )));
    }
    Ok(state.bytes.drain(..n).collect())
}

fn buffer_read_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let v = drain_front(state, 1)?;
        Ok(Value::Byte(v[0] as i8))
    })
}

fn buffer_read_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let bytes = drain_front(state, 4)?;
        let arr: [u8; 4] = bytes.as_slice().try_into().unwrap();
        Ok(Value::new_int(i32::from_be_bytes(arr) as i64))
    })
}

fn buffer_read_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let bytes = drain_front(state, 8)?;
        let arr: [u8; 8] = bytes.as_slice().try_into().unwrap();
        Ok(Value::Long(i64::from_be_bytes(arr)))
    })
}

fn buffer_read_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let bytes = drain_front(state, 2)?;
        let arr: [u8; 2] = bytes.as_slice().try_into().unwrap();
        Ok(Value::Short(i16::from_be_bytes(arr)))
    })
}

fn buffer_read_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let bytes: Vec<u8> = state.bytes.drain(..).collect();
        let s = String::from_utf8(bytes).map_err(|e| {
            RuntimeError::Type(format!("kotlinx.io.Buffer.readString: invalid UTF-8: {e}"))
        })?;
        Ok(Value::String(Rc::new(s)))
    })
}

/// Materialise the buffer's current contents as a `ByteString` —
/// modelled by a `Value::Array` of bytes. The buffer is left intact;
/// `snapshot` is a copy, matching kotlinx.io's semantics.
fn buffer_snapshot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    with_buffer(ctx, |state| {
        let items: Vec<Value> =
            state.bytes.iter().map(|b| Value::Byte(*b as i8)).collect();
        Ok(Value::Array {
            items: Rc::new(RefCell::new(items)),
            prim: Some(PrimitiveArrayKind::Byte),
        })
    })
}

fn buffer_copy_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Pull the source bytes first, releasing the borrow on the
    // source instance before we acquire the sink's native state.
    // Otherwise borrow_mut on the same Rc would alias when src and
    // sink happen to be the same Buffer (legal but rare).
    let src_bytes: VecDeque<u8> = with_buffer(ctx, |state| Ok(state.bytes.clone()))?;
    let Some(Value::Instance(sink_inst)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type(
            "kotlinx.io.Buffer.copyTo: sink must be a Buffer".into(),
        ));
    };
    let sink_cell = sink_inst
        .borrow_mut()
        .ensure_native_state(BUFFER_KIND, BufferState::default);
    let mut sink_borrow = sink_cell.borrow_mut();
    let sink: &mut BufferState = sink_borrow
        .downcast_mut::<BufferState>()
        .expect("buffer state type");
    sink.bytes.extend(src_bytes);
    Ok(Value::Unit)
}

fn byte_string_decode_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // ByteString shim stores the byte vector inside the `data`
    // field of the Value::Instance — it's a plain ByteArray
    // construction-time argument, not a native_state slot, so this
    // binding still reaches in through the field.
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
                Value::Byte(b) => *b as u8,
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
    Ok(Value::String(Rc::new(s)))
}

/// `String.encodeToByteString()` — top-level extension. Bytes
/// surface as a `Value::Array` so user code can `.toByteArray()` /
/// iterate; the shim layer rewraps if needed.
fn string_encode_to_byte_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => s.as_str().to_string(),
        _ => {
            return Err(RuntimeError::Type(
                "encodeToByteString: receiver must be a String".into(),
            ))
        }
    };
    let items: Vec<Value> = s.as_bytes().iter().map(|b| Value::Byte(*b as i8)).collect();
    Ok(Value::Array {
        items: Rc::new(RefCell::new(items)),
        prim: Some(PrimitiveArrayKind::Byte),
    })
}

// `InstanceData` is brought into scope above for documentation —
// suppress the unused-import warning when this gets minified.
#[allow(dead_code)]
fn _instance_data_in_scope(_: &InstanceData) {}
