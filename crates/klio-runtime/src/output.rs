use crate::float_fmt;
use std::sync::Arc;

pub trait Output {
    /// Write a string followed by a newline.
    fn writeln(&mut self, s: &str);
    /// Write a string with no trailing newline. Default implementation
    /// stores the partial line and flushes on the next `writeln`.
    fn write(&mut self, s: &str) {
        self.writeln(s);
    }
}

/// One recorded output call. A [`RecordingSink`] logs the exact
/// `write`/`writeln` sequence so it can later be replayed verbatim
/// into any `Output`, byte-for-byte and call-for-call.
#[derive(Clone)]
pub enum OutOp {
    Write(String),
    WriteLn(String),
}

/// `Send` sink that records the exact call sequence instead of
/// formatting eagerly. The root thread and every spawned thread
/// share one of these behind a `Mutex` (via [`SharedOutput`]); when
/// the program finishes, [`RecordingSink::replay_into`] reproduces
/// the calls in order on the caller's real sink. Because the replay
/// is the identical call sequence, a single-threaded program's
/// output is byte-identical to writing the caller's sink directly.
#[derive(Default)]
pub struct RecordingSink {
    pub ops: Vec<OutOp>,
}

impl RecordingSink {
    pub fn replay_into(&mut self, out: &mut dyn Output) {
        for op in self.ops.drain(..) {
            match op {
                OutOp::Write(s) => out.write(&s),
                OutOp::WriteLn(s) => out.writeln(&s),
            }
        }
    }
}

impl Output for RecordingSink {
    fn writeln(&mut self, s: &str) {
        self.ops.push(OutOp::WriteLn(s.to_string()));
    }
    fn write(&mut self, s: &str) {
        self.ops.push(OutOp::Write(s.to_string()));
    }
}

pub struct StdoutOutput;
impl Output for StdoutOutput {
    fn writeln(&mut self, s: &str) {
        println!("{s}");
    }
    fn write(&mut self, s: &str) {
        use std::io::Write;
        let _ = std::io::stdout().write_all(s.as_bytes());
        let _ = std::io::stdout().flush();
    }
}

/// Test helper that captures every line written to it.
#[derive(Default)]
pub struct CaptureOutput {
    pub lines: Vec<String>,
    partial: String,
}
impl Output for CaptureOutput {
    fn writeln(&mut self, s: &str) {
        if self.partial.is_empty() {
            self.lines.push(s.to_string());
        } else {
            let mut joined = std::mem::take(&mut self.partial);
            joined.push_str(s);
            self.lines.push(joined);
        }
    }
    fn write(&mut self, s: &str) {
        self.partial.push_str(s);
    }
}

/// A `Send` output sink shared by every OS thread of one program.
///
/// All threads (the root and every `kotlin.concurrent.thread` child)
/// write through the same `Arc<Mutex<dyn Output + Send>>`, so a
/// `println` is serialized at write granularity. Kotlin does not
/// define an ordering for racy output; the litmus programs gate their
/// prints behind join / `synchronized` so the observable order stays
/// deterministic.
///
/// Single-thread behaviour is byte-identical to writing the inner sink
/// directly: there is exactly one writer, the mutex is uncontended,
/// and `write`/`writeln` forward verbatim in the same program order.
#[derive(Clone, Default)]
pub struct SharedOutput(Arc<std::sync::Mutex<RecordingSink>>);

impl SharedOutput {
    #[must_use] 
    pub fn new() -> Self {
        Self::default()
    }

    /// Replay every recorded call, in order, into the caller's real
    /// sink, then clear the recording. Called once after the run and
    /// every spawned thread have completed.
    pub fn replay_into(&self, out: &mut dyn Output) {
        let mut g = self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        g.replay_into(out);
    }
}

impl Output for SharedOutput {
    fn writeln(&mut self, s: &str) {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).writeln(s);
    }
    fn write(&mut self, s: &str) {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner).write(s);
    }
}

/// Kotlin-compatible `Double.toString`. Mirrors Java/Kotlin output:
///   * `NaN` literal.
///   * `+/-Infinity` literal.
///   * Integer-valued finite doubles get a `.0` suffix (so `1.0`, not `1`).
///   * Scientific notation kicks in below `1e-3` or at/above `1e7`, with a
///     capital `E` and a `.0` in the mantissa if it's otherwise integer-valued.
#[must_use]
pub fn kotlin_float_to_string(d: f32) -> String {
    float_fmt::float_to_string(d)
}

#[must_use]
pub fn kotlin_double_to_string(d: f64) -> String {
    float_fmt::double_to_string(d)
}

/// Render a single Kotlin `Char` (a UTF-16 code unit) as a `String`. A
/// BMP scalar renders as itself; a lone surrogate renders as the Unicode
/// replacement character, since a Rust `String` cannot hold one.
#[must_use]
pub fn char_unit_to_string(unit: u16) -> String {
    String::from_utf16_lossy(&[unit])
}

/// Append a UTF-16 code unit to a `String`, pairing a pending high
/// surrogate (`prev`) with a following low surrogate into the astral
/// scalar. Returns the new pending high surrogate (the just-appended
/// unit if it is itself an unpaired high surrogate, else `None`). An
/// unpaired surrogate is flushed lossily as U+FFFD. This lets callers
/// fold a `Char` sequence (e.g. a `CharArray`) into a UTF-8 `String`
/// while reconstructing surrogate pairs.
pub fn push_char_unit(out: &mut String, prev: Option<u16>, unit: u16) -> Option<u16> {
    if let Some(hi) = prev {
        if (0xDC00..=0xDFFF).contains(&unit) {
            let c = 0x10000 + ((u32::from(hi) - 0xD800) << 10) + (u32::from(unit) - 0xDC00);
            out.push(char::from_u32(c).unwrap_or('\u{FFFD}'));
            return None;
        }
        out.push('\u{FFFD}'); // unpaired high surrogate
    }
    if (0xD800..=0xDBFF).contains(&unit) {
        return Some(unit); // hold as pending high surrogate
    }
    out.push(char::from_u32(u32::from(unit)).unwrap_or('\u{FFFD}'));
    None
}

/// Fold a sequence of UTF-16 code units into a `String`, reconstructing
/// surrogate pairs (and flushing any trailing unpaired high surrogate).
#[must_use]
pub fn char_units_to_string<I: IntoIterator<Item = u16>>(units: I) -> String {
    let mut out = String::new();
    let mut pending: Option<u16> = None;
    for u in units {
        pending = push_char_unit(&mut out, pending, u);
    }
    if pending.is_some() {
        out.push('\u{FFFD}');
    }
    out
}
