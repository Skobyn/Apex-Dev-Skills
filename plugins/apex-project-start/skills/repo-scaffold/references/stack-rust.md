# Stack: Rust

Modern defaults (2025–2026): **cargo** + **clippy** (lints) + **rustfmt** (format) — both ship with the toolchain; wire both into CI. Pin the toolchain with `rust-toolchain.toml`.

## Tooling decisions

| Concern | Default | Notes |
|---|---|---|
| Build/deps | `cargo new --lib` (library) / `cargo new` (binary) | edition 2021 |
| Lint | **clippy** with `-D warnings` in CI | catches idiom + correctness issues |
| Format | **rustfmt** (`cargo fmt --check` in CI) | `rustfmt.toml` for overrides |
| Toolchain pin | `rust-toolchain.toml` | reproducible builds |
| Test | built-in `#[test]` + `cargo test` | — |

## Files to generate

### `Cargo.toml`
```toml
[package]
name = "<project-name>"
version = "0.1.0"
edition = "2021"
description = "<purpose>"
license = "<SPDX>"
authors = ["skobyn <skobyn@gmail.com>"]
readme = "README.md"

[dependencies]

[dev-dependencies]
```

### Source + test
`src/lib.rs` (library):
```rust
/// Returns a friendly greeting.
pub fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greets_by_name() {
        assert_eq!(greet("world"), "Hello, world!");
    }
}
```
For a binary, `src/main.rs` calling the logic; consider lib + thin main for testability.

### `rust-toolchain.toml`
```toml
[toolchain]
channel = "stable"
components = ["rustfmt", "clippy"]
```

### `rustfmt.toml`
```toml
edition = "2021"
max_width = 100
```

### `.cargo/config.toml` (optional, lint gate)
```toml
[target.'cfg(all())']
rustflags = ["-Dwarnings"]
```

### `mise.toml`
```toml
[tools]
rust = "stable"
```

## Extend `.gitignore`
```
/target/
**/*.rs.bk
Cargo.lock   # keep for binaries; remove this line (commit Cargo.lock) for applications
```
Note: commit `Cargo.lock` for binaries/apps; omit for libraries.

## Finalize commands
```bash
cargo build
cargo test
cargo clippy -- -D warnings
cargo fmt --check
```
