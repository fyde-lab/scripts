use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::Local;
use fyde_sdk::ProgressEvent;
use serde_json::{Value, json};

/// Per-run debug report, ported from `demo-rust-fyde`'s `report.rs`: every
/// event (run start/finish, scraper progress) is appended to a single JSON
/// array and the whole file is rewritten after each entry, so it stays
/// valid JSON even if the run crashes partway through. Written under
/// `--report-dir` (gitignored, like `--documents-dir`/`--storage`).
#[derive(Clone)]
pub struct Report {
    path: PathBuf,
    entries: Arc<Mutex<Vec<Value>>>,
}

impl Report {
    /// Starts a new report for `scraper_name` at
    /// `<report_dir>/<scraper_name>_<dd-mm-yy>_<hh-mm-ss>.json`.
    pub fn start(report_dir: &Path, scraper_name: &str) -> Self {
        let filename = format!(
            "{scraper_name}_{}.json",
            Local::now().format("%d-%m-%y_%H-%M-%S")
        );

        Self {
            path: report_dir.join(filename),
            entries: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Records one `(event_type, value)` entry and rewrites the report file.
    /// A write failure is swallowed — this is a debugging aid only, and must
    /// never make a scraper run fail because its report directory couldn't
    /// be created or written to.
    pub fn record(&self, event_type: &str, value: Value) {
        self.push(json!({
            "timestamp": Local::now().to_rfc3339(),
            "event_type": event_type,
            "value": value,
        }));
    }

    /// Records a `fyde.progress.step`/`fyde.progress.update` call.
    pub fn record_progress(&self, event: &ProgressEvent) {
        match event {
            ProgressEvent::Step { name } => self.record("progress_step", json!({ "name": name })),
            ProgressEvent::Update {
                current,
                total,
                message,
            } => self.record(
                "progress_update",
                json!({ "current": current, "total": total, "message": message }),
            ),
        }
    }

    fn push(&self, entry: Value) {
        let mut entries = self.entries.lock().unwrap();
        entries.push(entry);

        let Some(parent) = self.path.parent() else {
            return;
        };
        if fs::create_dir_all(parent).is_err() {
            return;
        }
        if let Ok(text) = serde_json::to_string_pretty(&*entries) {
            let _ = fs::write(&self.path, text);
        }
    }
}
