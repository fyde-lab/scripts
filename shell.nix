{ pkgs ? import <nixpkgs> {
    overlays = [
      (import (builtins.fetchTarball
        "https://github.com/oxalica/rust-overlay/archive/master.tar.gz"))
    ];
  }
}:

let
  # Must match ../sdk's toolchain: this crate's dependency on fyde-sdk pulls
  # in wreq/wreq-util (`../sdk/src/domains/scrapers/host/http.rs`), which
  # require rustc >=1.98.
  rustToolchain = pkgs.rust-bin.stable."1.98.1".default.override {
    extensions = [ "rust-src" "clippy" "rustfmt" "rust-analyzer" ];
  };
in
pkgs.mkShell {
  packages = with pkgs; [
    claude-code

    rustToolchain
    sccache

    # fyde-sdk's build.rs needs this to compile
    # the buf.build/fyde-lab/api protos via tonic-prost-build.
    protobuf

    # ../sdk's build also vendors a patched BoringSSL (btls-sys) for wreq's
    # Chrome TLS/HTTP2 fingerprint - these are its native build deps.
    cmake
    perl
    go
    clang
    # Sets up LIBCLANG_PATH/BINDGEN_EXTRA_CLANG_ARGS correctly for bindgen.
    rustPlatform.bindgenHook

    # required (via pkg-config) to build wry/tao, the real embedded webview
    # behind fyde.browser (../sdk/src/domains/scrapers/browser/driver.rs and
    # ../sdk/src/domains/scrapers/host/browser.rs). webkitgtk_4_1/gtk3 are
    # wry's WebKitGTK backend on Linux; dbus is tao's optional single-
    # instance/app-id support, pulled in by its "dbus" feature. Must mirror
    # ../sdk/shell.nix's own copy of these - this crate depends on fyde-sdk,
    # so it links the same wry/tao code.
    pkg-config
    webkitgtk_4_1
    gtk3
    dbus

    # webkitgtk's HTTPS support goes through GIO's TLS backend, which nixpkgs
    # ships as a separate GIO module (glib-networking) rather than bundling
    # it into webkitgtk/glib themselves - without it registered via
    # GIO_EXTRA_MODULES below, every HTTPS navigation inside the webview
    # fails outright with WebKit's own "TLS support is not available" error
    # page, with no Rust-visible error (load_url/evaluate_script both still
    # report success - only the page content itself shows the failure). Must
    # mirror ../sdk/shell.nix's own copy of this, same reasoning as the
    # webkitgtk_4_1/gtk3/dbus packages above.
    glib-networking
  ];

  # direnv (`use nix`) caches the env from the nix-shell invocation that computed it,
  # including the ephemeral TMPDIR nix-shell creates and deletes on exit. Later shells
  # reusing that cached env point sccache at a TMPDIR that's already gone - pin it.
  shellHook = ''
    export TMPDIR="/tmp"

    export RUSTC_WRAPPER=${pkgs.sccache}/bin/sccache
    export SCCACHE_DIR="$HOME/.cache/sccache"
    export CC="${pkgs.sccache}/bin/sccache ${pkgs.clang}/bin/clang"
    export CXX="${pkgs.sccache}/bin/sccache ${pkgs.clang}/bin/clang++"

    # See the `glib-networking` comment above - GIO only looks for TLS/proxy
    # backend modules on this path, which nixpkgs never adds to a plain
    # shell's environment on its own.
    export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
  '';
}
