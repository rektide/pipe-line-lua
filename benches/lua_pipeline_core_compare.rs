use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use std::path::Path;
use std::process::Command;
use std::time::Duration;

const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");
const LUA_SCRIPT: &str = "benches/lua/core_pipeline_compare.lua";
const IMPLEMENTATIONS: &[&str] = &[
    "single-stage-table",
    "single-stage-mode",
    "sync-or-mpsc-core",
];

#[derive(Clone)]
struct BenchmarkCase {
    implementation: &'static str,
}

fn has_implementation(name: &str) -> bool {
    Path::new(MANIFEST_DIR)
        .join("implementations")
        .join(name)
        .join("lua/termichatter/init.lua")
        .is_file()
}

fn run_script(case: &BenchmarkCase) -> Result<(), String> {
    let output = Command::new("nvim")
        .current_dir(MANIFEST_DIR)
        .env("TERMICHATTER_IMPL", case.implementation)
        .env("TERMICHATTER_BENCH_COUNT", "600")
        .args([
            "--headless",
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-n",
            "-l",
            LUA_SCRIPT,
        ])
        .output()
        .map_err(|err| format!("failed to execute nvim: {err}"))?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "benchmark command failed for implementation={}\nstdout:\n{}\nstderr:\n{}",
            case.implementation, stdout, stderr
        ));
    }

    Ok(())
}

fn benchmark_core_pipeline(c: &mut Criterion) {
    let mut cases = Vec::new();
    for implementation in IMPLEMENTATIONS {
        if has_implementation(implementation) {
            cases.push(BenchmarkCase { implementation });
        }
    }

    if cases.is_empty() {
        panic!("no benchmark implementations found");
    }

    let mut preflight_failures = Vec::new();
    for case in &cases {
        if let Err(err) = run_script(case) {
            preflight_failures.push(err);
        }
    }
    if !preflight_failures.is_empty() {
        let joined = preflight_failures.join("\n\n");
        panic!("Core pipeline benchmark preflight failed.\n\n{joined}");
    }

    let mut group = c.benchmark_group("lua_core_pipeline_compare");
    group.sample_size(12);
    group.warm_up_time(Duration::from_secs(2));
    group.measurement_time(Duration::from_secs(12));

    for case in &cases {
        group.bench_function(BenchmarkId::new("impl", case.implementation), |b| {
            b.iter(|| run_script(black_box(case)).expect("benchmark run failed"));
        });
    }

    group.finish();
}

criterion_group!(benches, benchmark_core_pipeline);
criterion_main!(benches);
