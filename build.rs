use std::path::{Path, PathBuf};
use std::process::Command;

const BUF_MODULE: &str = "buf.build/fyde-lab/api";

/// Points the build at a local checkout of the protos (e.g. `../server/protos`)
/// instead of fetching [`BUF_MODULE`] from the BSR — the same variable
/// `fyde-sdk`'s own build script reads.
const PROTO_DIR_ENV: &str = "FYDE_PROTO_DIR";

/// Compiles the two gRPC services `publish` calls directly: `users.v1` (to
/// log in and out) and `admin.v1` (to write scripts and icons). Only their
/// clients: this program never serves them.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let proto_dir = match std::env::var_os(PROTO_DIR_ENV) {
        Some(dir) => {
            let dir = PathBuf::from(dir);
            println!("cargo:rerun-if-env-changed={PROTO_DIR_ENV}");
            println!("cargo:rerun-if-changed={}", dir.display());
            dir
        }
        // No rerun-if directive here, so Cargo reruns this script on every
        // build and never compiles against a stale copy of the BSR module.
        None => export_from_bsr()?,
    };

    tonic_prost_build::configure()
        .build_server(false)
        .compile_protos(
            &[
                proto_dir.join("users/v1/users.proto"),
                proto_dir.join("admin/v1/admin.proto"),
            ],
            &[proto_dir],
        )?;

    Ok(())
}

/// Exports [`BUF_MODULE`] into `OUT_DIR` with `buf` and returns where it went.
fn export_from_bsr() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let out_dir = std::env::var("OUT_DIR")?;
    let proto_dir = Path::new(&out_dir).join("api-protos");

    let status = Command::new("buf")
        .args(["export", BUF_MODULE, "-o"])
        .arg(&proto_dir)
        .status()
        .map_err(|err| format!("failed to run buf (or set {PROTO_DIR_ENV}): {err}"))?;
    if !status.success() {
        return Err(format!("buf export {BUF_MODULE} failed with status {status}").into());
    }

    Ok(proto_dir)
}
