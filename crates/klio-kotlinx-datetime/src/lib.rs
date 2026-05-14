//! Native bindings for `kotlinx-datetime`.
//!
//! The Kotlin shim under `shim/` declares the public API; the bindings
//! here expose host-side helpers the shim calls into:
//!
//! - system clock (`__kxdt_currentTimeMillis`,
//!   `__kxdt_currentNanosOfSecond`, `__kxdt_currentSystemTimeZoneId`)
//! - `Instant` ↔ `LocalDateTime` conversion in a given IANA tz, via
//!   `chrono` + `chrono-tz`
//! - ISO-8601 rendering and parsing of `Instant`
//! - tz id validation
//!
//! Top-level arithmetic, formatting of `LocalDate` / `LocalTime` /
//! `LocalDateTime`, and operator dispatch are pure-Kotlin in the shim.

use std::cell::RefCell;
use std::rc::Rc;

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike, Utc};
use chrono_tz::Tz;
use klio_runtime::{CallCtx, PrimitiveArrayKind, RuntimeError, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "kotlinx.datetime.__kxdt_currentTimeMillis"       => current_time_millis,
        "kotlinx.datetime.__kxdt_currentNanosOfSecond"    => current_nanos_of_second,
        "kotlinx.datetime.__kxdt_currentSystemTimeZoneId" => current_system_tz_id,
        "kotlinx.datetime.__kxdt_instantToLocalParts"     => instant_to_local_parts,
        "kotlinx.datetime.__kxdt_localToInstant"          => local_to_instant,
        "kotlinx.datetime.__kxdt_instantToString"         => instant_to_string,
        "kotlinx.datetime.__kxdt_parseInstant"            => parse_instant,
        "kotlinx.datetime.__kxdt_validateTimeZone"        => validate_time_zone,
        "kotlinx.datetime.__kxdt_addPeriod"               => add_period,
    }
}

fn current_time_millis(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let now = Utc::now();
    Ok(Value::Long(now.timestamp_millis()))
}

fn current_nanos_of_second(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let now = Utc::now();
    Ok(Value::new_int(now.timestamp_subsec_nanos() as i64))
}

fn current_system_tz_id(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".to_string());
    Ok(Value::String(Rc::new(id)))
}

fn arg_long(ctx: &CallCtx, idx: usize) -> Result<i64, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::Long(l)) => Ok(*l),
        Some(Value::Int(i)) => Ok(*i as i64),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.datetime: argument {idx} must be Int/Long"
        ))),
    }
}

fn arg_i32(ctx: &CallCtx, idx: usize) -> Result<i32, RuntimeError> {
    Ok(arg_long(ctx, idx)? as i32)
}

fn arg_str(ctx: &CallCtx, idx: usize) -> Result<String, RuntimeError> {
    match ctx.args.get(idx) {
        Some(Value::String(s)) => Ok(s.as_str().to_string()),
        _ => Err(RuntimeError::Type(format!(
            "kotlinx.datetime: argument {idx} must be String"
        ))),
    }
}

fn parse_tz(id: &str) -> Option<Tz> {
    if id == "Z" {
        return Some(Tz::UTC);
    }
    id.parse::<Tz>().ok()
}

fn make_long_array(values: &[i64]) -> Value {
    let items: Vec<Value> = values.iter().map(|v| Value::Long(*v)).collect();
    Value::Array {
        items: Rc::new(RefCell::new(items)),
        prim: Some(PrimitiveArrayKind::Long),
    }
}

fn instant_to_local_parts(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let epoch_sec = arg_long(ctx, 0)?;
    let nanos = arg_i32(ctx, 1)? as u32;
    let tz_id = arg_str(ctx, 2)?;
    let utc = Utc.timestamp_opt(epoch_sec, nanos).single().ok_or_else(|| {
        RuntimeError::Type(format!("invalid epoch seconds: {epoch_sec}"))
    })?;
    let local = match parse_tz(&tz_id) {
        Some(tz) => utc.with_timezone(&tz).naive_local(),
        None => utc.naive_utc(),
    };
    Ok(make_long_array(&[
        local.year() as i64,
        local.month() as i64,
        local.day() as i64,
        local.hour() as i64,
        local.minute() as i64,
        local.second() as i64,
        local.nanosecond() as i64,
    ]))
}

fn local_to_instant(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let year = arg_i32(ctx, 0)?;
    let month = arg_i32(ctx, 1)? as u32;
    let day = arg_i32(ctx, 2)? as u32;
    let hour = arg_i32(ctx, 3)? as u32;
    let minute = arg_i32(ctx, 4)? as u32;
    let second = arg_i32(ctx, 5)? as u32;
    let nano = arg_i32(ctx, 6)? as u32;
    let tz_id = arg_str(ctx, 7)?;
    let date = NaiveDate::from_ymd_opt(year, month, day)
        .ok_or_else(|| RuntimeError::Type(format!("invalid date {year}-{month}-{day}")))?;
    let time = NaiveTime::from_hms_nano_opt(hour, minute, second, nano)
        .ok_or_else(|| RuntimeError::Type("invalid time-of-day".into()))?;
    let naive = NaiveDateTime::new(date, time);
    let utc: DateTime<Utc> = match parse_tz(&tz_id) {
        Some(tz) => tz.from_local_datetime(&naive).single().ok_or_else(|| {
            RuntimeError::Type("ambiguous or non-existent local time".into())
        })?.with_timezone(&Utc),
        None => Utc.from_utc_datetime(&naive),
    };
    Ok(make_long_array(&[utc.timestamp(), utc.timestamp_subsec_nanos() as i64]))
}

fn instant_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let epoch_sec = arg_long(ctx, 0)?;
    let nanos = arg_i32(ctx, 1)? as u32;
    let dt = Utc.timestamp_opt(epoch_sec, nanos).single().ok_or_else(|| {
        RuntimeError::Type(format!("invalid epoch seconds: {epoch_sec}"))
    })?;
    Ok(Value::String(Rc::new(dt.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true))))
}

fn parse_instant(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let input = arg_str(ctx, 0)?;
    let dt = DateTime::<FixedOffset>::parse_from_rfc3339(&input).map_err(|e| {
        RuntimeError::Type(format!("failed to parse Instant `{input}`: {e}"))
    })?;
    let utc = dt.with_timezone(&Utc);
    Ok(make_long_array(&[utc.timestamp(), utc.timestamp_subsec_nanos() as i64]))
}

fn validate_time_zone(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let id = arg_str(ctx, 0)?;
    Ok(Value::Bool(parse_tz(&id).is_some() || id == "UTC"))
}

/// Apply a calendar period in the given tz.
///
/// Arguments: epochSeconds, nanos, years, months, days, hours,
/// minutes, seconds, nanoAdjust, tzId. Returns `[epochSeconds, nanos]`.
fn add_period(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use chrono::Months;
    let epoch_sec = arg_long(ctx, 0)?;
    let nanos = arg_i32(ctx, 1)? as u32;
    let years = arg_i32(ctx, 2)?;
    let months = arg_i32(ctx, 3)?;
    let days = arg_i32(ctx, 4)?;
    let hours = arg_i32(ctx, 5)?;
    let minutes = arg_i32(ctx, 6)?;
    let seconds = arg_i32(ctx, 7)?;
    let nano_adjust = arg_long(ctx, 8)?;
    let tz_id = arg_str(ctx, 9)?;
    let utc = Utc.timestamp_opt(epoch_sec, nanos).single().ok_or_else(|| {
        RuntimeError::Type(format!("invalid epoch seconds: {epoch_sec}"))
    })?;
    let total_months = (years as i64) * 12 + (months as i64);
    let local: chrono::DateTime<chrono::FixedOffset> = match parse_tz(&tz_id) {
        Some(tz) => utc.with_timezone(&tz).fixed_offset(),
        None => utc.fixed_offset(),
    };
    let mut shifted = local;
    if total_months != 0 {
        let abs = total_months.unsigned_abs();
        let months = Months::new(abs.min(u32::MAX as u64) as u32);
        shifted = if total_months > 0 {
            shifted.checked_add_months(months)
        } else {
            shifted.checked_sub_months(months)
        }
        .ok_or_else(|| RuntimeError::Type("DateTimePeriod month overflow".into()))?;
    }
    let secs = (days as i64) * 86_400
        + (hours as i64) * 3_600
        + (minutes as i64) * 60
        + (seconds as i64);
    let total_nanos = nano_adjust + secs * 1_000_000_000;
    let dur = chrono::Duration::nanoseconds(total_nanos);
    shifted = shifted
        .checked_add_signed(dur)
        .ok_or_else(|| RuntimeError::Type("DateTimePeriod time overflow".into()))?;
    let utc_back = shifted.with_timezone(&Utc);
    Ok(make_long_array(&[
        utc_back.timestamp(),
        utc_back.timestamp_subsec_nanos() as i64,
    ]))
}
