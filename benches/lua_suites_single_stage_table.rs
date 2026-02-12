use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const IMPLEMENTATION: &str = "single-stage-table";
const SUITE_DIR: &str = "tests/termichatter";
const BUSTED_ENTRYPOINT: &str = "tests/busted.lua";
const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");

#[derive(Clone)]
struct BenchmarkCase {
    suite_path: PathBuf,
}

fn suite_paths() -> Vec<PathBuf> {
    let entries = fs::read_dir(Path::new(MANIFEST_DIR).join(SUITE_DIR))
        .unwrap_or_else(|err| panic!("failed to read test suite directory: {err}"));

    let mut suites = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .filter(|path| {
            path.file_name()
                .and_then(OsStr::to_str)
                .map(|name| name.ends_with("_spec.lua"))
                .unwrap_or(false)
        })
        .collect::<Vec<_>>();

    suites.sort();

    if suites.is_empty() {
        panic!("no *_spec.lua suites found in {SUITE_DIR}");
    }

    suites
}

fn suite_name(path: &Path) -> String {
    path.file_stem()
        .and_then(OsStr::to_str)
        .map(|name| name.trim_end_matches("_spec"))
        .unwrap_or("unknown_suite")
        .to_owned()
}

fn run_suite(case: &BenchmarkCase) -> Result<(), String> {
    let path = case.suite_path.as_path();
    let suite_arg = path.to_string_lossy().into_owned();

    let output = Command::new("nvim")
        .current_dir(MANIFEST_DIR)
        .env("TERMICHATTER_IMPL", IMPLEMENTATION)
        .args([
            "--headless",
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-n",
            "-l",
            BUSTED_ENTRYPOINT,
            suite_arg.as_str(),
        ])
        .output()
        .map_err(|err| format!("failed to execute nvim for suite {suite_arg}: {err}"))?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "suite benchmark command failed for implementation={IMPLEMENTATION} suite={suite_arg}\nstdout:\n{stdout}\nstderr:\n{stderr}"
        ));
    }

    Ok(())
}

fn benchmark_lua_suites_single_stage_table(c: &mut Criterion) {
    let suites = suite_paths();
    let mut cases = Vec::new();
    for suite in &suites {
        cases.push(BenchmarkCase {
            suite_path: suite.clone(),
        });
    }

    let mut preflight_failures = Vec::new();
    for case in &cases {
        if let Err(err) = run_suite(case) {
            preflight_failures.push(err);
        }
    }
    if !preflight_failures.is_empty() {
        let joined = preflight_failures.join("\n\n");
        panic!("Lua suite preflight failed. Fix failing suites before benchmarking.\n\n{joined}");
    }

    let mut group = c.benchmark_group("lua_testsuites_single_stage_table");
    group.sample_size(10);
    group.warm_up_time(Duration::from_secs(2));
    group.measurement_time(Duration::from_secs(10));

    for case in &cases {
        let suite = suite_name(case.suite_path.as_path());
        let id = format!("{IMPLEMENTATION}/{suite}");
        group.bench_function(BenchmarkId::new("impl_suite", id), |b| {
            b.iter(|| run_suite(black_box(case)).expect("suite failed during benchmark"));
        });
    }

    group.finish();
}

criterion_group!(benches, benchmark_lua_suites_single_stage_table);
criterion_main!(benches);
