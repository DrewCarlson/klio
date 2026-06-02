//! Stable JSON schema for bench records + baseline diffing.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BenchRecord {
    pub stage: String,
    pub workload: String,
    pub median_ns: u64,
    pub p99_ns: u64,
    pub iters: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allocs: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alloc_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ref_kotlinc_native_ns: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ref_kotlinc_jvm_ns: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BenchReport {
    pub git_sha: String,
    pub host: String,
    pub records: Vec<BenchRecord>,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum RegressionLevel {
    Green,
    Yellow,
    Red,
}

impl RegressionLevel {
    #[must_use]
    pub fn classify(ratio: f64) -> Self {
        if ratio >= 1.15 {
            Self::Red
        } else if ratio >= 1.05 {
            Self::Yellow
        } else {
            Self::Green
        }
    }
}

/// Diff the `median_ns` of `cur` vs. `base`. Returns one row per workload
/// present in `cur` (missing baselines emit ratio 1.0 + Green).
#[must_use]
// timing ratio is approximate; f64 precision loss on large ns counts is fine
#[allow(clippy::cast_precision_loss)]
pub fn diff(base: &BenchReport, cur: &BenchReport) -> Vec<DiffRow> {
    let mut rows = Vec::new();
    for r in &cur.records {
        let key = (r.stage.as_str(), r.workload.as_str());
        let base_ns = base
            .records
            .iter()
            .find(|b| b.stage == key.0 && b.workload == key.1)
            .map(|b| b.median_ns);
        let ratio = match base_ns {
            Some(b) if b > 0 => r.median_ns as f64 / b as f64,
            _ => 1.0,
        };
        rows.push(DiffRow {
            stage: r.stage.clone(),
            workload: r.workload.clone(),
            base_ns,
            cur_ns: r.median_ns,
            ratio,
            level: RegressionLevel::classify(ratio),
        });
    }
    rows
}

#[derive(Clone, Debug)]
pub struct DiffRow {
    pub stage: String,
    pub workload: String,
    pub base_ns: Option<u64>,
    pub cur_ns: u64,
    pub ratio: f64,
    pub level: RegressionLevel,
}
