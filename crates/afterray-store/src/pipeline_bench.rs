#![allow(clippy::cast_precision_loss, clippy::too_many_lines)]

use super::{decrypt_artifact, encrypt_artifact};
use afterray_protocol::{ArtifactPayload, Response};
use std::{
    env, fs,
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::{Duration, Instant},
};

#[test]
#[ignore = "manual pipeline bench; run with --ignored --nocapture"]
fn bench_daemon_artifact_stages() {
    let jpeg = load_fixture();
    eprintln!(
        "\n=== afterray daemon artifact stages ===\nfixture: {} ({:.1} KB)",
        jpeg.label,
        jpeg.bytes.len() as f64 / 1024.0
    );

    let key = [0x42_u8; 32];
    let artifact_id = "bench-artifact";
    let content_type = "image/jpeg";
    let encrypted = encrypt_artifact(&key, artifact_id, content_type, &jpeg.bytes).unwrap();
    let encrypted_path = std::env::temp_dir().join("afterray-bench-artifact.arv1");
    fs::write(&encrypted_path, &encrypted.bytes).unwrap();

    let rounds = 12;
    let warmup = 2;
    let mut rows = Vec::new();

    rows.push(measure(
        "encrypt (capture, not on scrub)",
        rounds,
        warmup,
        || {
            let _ = encrypt_artifact(&key, artifact_id, content_type, &jpeg.bytes).unwrap();
        },
    ));
    rows.push(measure(
        "fs write encrypted (capture)",
        rounds,
        warmup,
        || {
            fs::write(&encrypted_path, &encrypted.bytes).unwrap();
        },
    ));
    rows.push(measure("fs read encrypted", rounds, warmup, || {
        let _ = fs::read(&encrypted_path).unwrap();
    }));
    rows.push(measure("decrypt", rounds, warmup, || {
        let _ = decrypt_artifact(
            &key,
            artifact_id,
            content_type,
            &encrypted.bytes,
            &encrypted.wrapped_dek,
            &encrypted.wrapping_nonce,
        )
        .unwrap();
    }));

    let plaintext = decrypt_artifact(
        &key,
        artifact_id,
        content_type,
        &encrypted.bytes,
        &encrypted.wrapped_dek,
        &encrypted.wrapping_nonce,
    )
    .unwrap();
    let payload = ArtifactPayload {
        id: artifact_id.to_owned(),
        content_type: content_type.to_owned(),
        bytes: plaintext.to_vec(),
    };
    rows.push(measure(
        "serde_json::to_value (Response::success)",
        rounds,
        warmup,
        || {
            let _ = serde_json::to_value(payload.meta()).unwrap();
        },
    ));

    let response = Response::success(payload.meta());
    rows.push(measure(
        "serde_json::to_vec response",
        rounds,
        warmup,
        || {
            let mut encoded = serde_json::to_vec(&response).unwrap();
            encoded.push(b'\n');
        },
    ));

    let header = payload.header_line().unwrap();
    let mut wire_payload = header.clone();
    wire_payload.extend_from_slice(&payload.bytes);
    eprintln!(
        "wire payload: {:.1} KB ({:.0}% of jpeg)",
        wire_payload.len() as f64 / 1024.0,
        wire_payload.len() as f64 / jpeg.bytes.len() as f64 * 100.0
    );

    rows.push(measure(
        "unix socket write+read json line",
        rounds,
        warmup,
        || {
            echo_unix(&wire_payload);
        },
    ));
    rows.push(measure("serde_json parse response", rounds, warmup, || {
        let parsed: serde_json::Value =
            serde_json::from_slice(&header[..header.len() - 1]).unwrap();
        assert!(parsed["ok"].as_bool().unwrap());
    }));

    rows.push(measure(
        "scrub miss subtotal: read+decrypt+header+socket",
        rounds,
        warmup,
        || {
            let on_disk = fs::read(&encrypted_path).unwrap();
            let bytes = decrypt_artifact(
                &key,
                artifact_id,
                content_type,
                &on_disk,
                &encrypted.wrapped_dek,
                &encrypted.wrapping_nonce,
            )
            .unwrap();
            let encoded = ArtifactPayload {
                id: artifact_id.to_owned(),
                content_type: content_type.to_owned(),
                bytes: bytes.to_vec(),
            };
            let mut wire = encoded.header_line().unwrap();
            wire.extend_from_slice(&encoded.bytes);
            echo_unix(&wire);
        },
    ));

    print_table(&rows);
    let _ = fs::remove_file(encrypted_path);
}

struct Fixture {
    label: String,
    bytes: Vec<u8>,
}

fn load_fixture() -> Fixture {
    if let Ok(path) = env::var("AFTERRAY_BENCH_JPEG") {
        let bytes = fs::read(&path).unwrap_or_else(|error| {
            panic!("failed to read AFTERRAY_BENCH_JPEG ({path}): {error}");
        });
        return Fixture { label: path, bytes };
    }
    let default = PathBuf::from("/tmp/afterray-bench/busy.jpg");
    if default.exists() {
        return Fixture {
            label: default.display().to_string(),
            bytes: fs::read(&default).unwrap(),
        };
    }
    Fixture {
        label: "synthetic 1.5MB blob".to_owned(),
        bytes: vec![0x5A; 1_500_000],
    }
}

fn echo_unix(payload: &[u8]) {
    let (mut server, mut client) = UnixStream::pair().unwrap();
    let to_send = payload.to_vec();
    let worker = std::thread::spawn(move || {
        client.write_all(&to_send).unwrap();
        let mut echoed = vec![0_u8; to_send.len()];
        client.read_exact(&mut echoed).unwrap();
        echoed
    });
    let mut received = vec![0_u8; payload.len()];
    server.read_exact(&mut received).unwrap();
    server.write_all(&received).unwrap();
    let echoed = worker.join().expect("unix echo thread");
    assert_eq!(echoed.len(), payload.len());
}

struct Row {
    name: &'static str,
    median_ms: f64,
    p95_ms: f64,
    mean_ms: f64,
}

fn measure(name: &'static str, rounds: usize, warmup: usize, mut body: impl FnMut()) -> Row {
    eprint!("  {name}… ");
    for _ in 0..warmup {
        body();
    }
    let mut samples = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let started = Instant::now();
        body();
        samples.push(started.elapsed());
    }
    samples.sort();
    let row = Row {
        name,
        median_ms: millis(samples[samples.len() / 2]),
        p95_ms: millis(
            samples[samples
                .len()
                .saturating_sub(1)
                .min((samples.len() * 95) / 100)],
        ),
        mean_ms: millis(samples.iter().sum::<Duration>() / u32::try_from(samples.len()).unwrap()),
    };
    eprintln!("{:.2}ms", row.median_ms);
    row
}

fn millis(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1_000.0
}

fn print_table(rows: &[Row]) {
    eprintln!(
        "\n{:<56} {:>10} {:>10} {:>10}",
        "stage", "median", "p95", "mean"
    );
    eprintln!("{}", "-".repeat(90));
    for row in rows {
        eprintln!(
            "{:<56} {:>8.2}ms {:>8.2}ms {:>8.2}ms",
            row.name, row.median_ms, row.p95_ms, row.mean_ms
        );
    }
    eprintln!();
}
