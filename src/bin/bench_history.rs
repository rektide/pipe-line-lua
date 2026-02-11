use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const HISTORY_DIR: &str = ".criterion-history";
const RUN_LOG_PATH: &str = ".criterion-history/runs.jsonl";

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is before UNIX_EPOCH")
        .as_secs()
}

fn git_commit_short() -> Option<String> {
    let output = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let commit = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if commit.is_empty() {
        None
    } else {
        Some(commit)
    }
}

fn append_run_log(history_id: &str, history_description: &str) {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(RUN_LOG_PATH)
        .expect("failed to open run history log");

    let now = unix_now();
    let line = format!(
        "{{\"timestamp_unix\":{now},\"history_id\":\"{history_id}\",\"history_description\":\"{history_description}\"}}\n"
    );

    file.write_all(line.as_bytes())
        .expect("failed to append run history log");
}

fn main() {
    fs::create_dir_all(Path::new(HISTORY_DIR)).expect("failed to create history directory");

    let now = unix_now();
    let commit = git_commit_short().unwrap_or_else(|| "no-git".to_owned());
    let history_id = format!("{now}-{commit}");
    let history_description = format!("Lua suite benchmark run {history_id}");

    let mut command = Command::new("cargo");
    command
        .arg("criterion")
        .arg("--bench")
        .arg("lua_suites")
        .arg("--history-id")
        .arg(&history_id)
        .arg("--history-description")
        .arg(&history_description)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    println!("Running cargo criterion with history id {history_id}");

    let status = command
        .status()
        .expect("failed to spawn cargo criterion command");
    if !status.success() {
        std::process::exit(status.code().unwrap_or(1));
    }

    append_run_log(&history_id, &history_description);

    println!("Saved history id {history_id}");
    println!("Run history log: {RUN_LOG_PATH}");
    println!("HTML report: target/criterion/report/index.html");
}
