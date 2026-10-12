#!/usr/bin/env bash
set -euo pipefail

cli_path="${1:?usage: verify-cli-linux-arm64-app.sh CLI_PATH CLI_TARGET}"
cli_target="${2:?usage: verify-cli-linux-arm64-app.sh CLI_PATH CLI_TARGET}"
repo_root="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"

case "$cli_target" in
  aarch64-unknown-linux-gnu | aarch64-unknown-linux-musl) ;;
  *)
    echo "Unsupported packaged CLI target: $cli_target" >&2
    exit 2
    ;;
esac

if [[ "$(uname -m)" != aarch64 ]]; then
  echo "Application validation must run on native ARM64" >&2
  exit 1
fi
if [[ "$cli_path" != /* || ! -x "$cli_path" ]]; then
  echo "CLI path must be an absolute executable artifact path: $cli_path" >&2
  exit 1
fi
case "$cli_path" in
  "$repo_root"/target/*)
    echo "Refusing a CLI from the repository build target directory" >&2
    exit 1
    ;;
esac

evidence_dir="$runner_temp/tauri-arm64-app-$cli_target"
mkdir -p "$evidence_dir"

expected_version="$(jq -r '."cli.js".version' "$repo_root/crates/tauri-cli/metadata-v2.json")"
test -n "$expected_version" && test "$expected_version" != null
version_output="$("$cli_path" --version)"
printf '%s\n' "$version_output" | tee "$evidence_dir/cli-version.txt"
[[ "$version_output" == *"$expected_version"* ]]
"$cli_path" info 2>&1 | tee "$evidence_dir/cli-info.txt"

"$cli_path" build \
  --ci \
  --target aarch64-unknown-linux-gnu \
  --bundles deb \
  --config '{"identifier":"com.tauri.cliarm64smoke"}' \
  -- --locked 2>&1 | tee "$evidence_dir/build.log"

git -C "$repo_root" diff --exit-code -- Cargo.lock > "$evidence_dir/cargo-lock-diff.txt"
bundle_dir="$repo_root/target/aarch64-unknown-linux-gnu/release/bundle/deb"
shopt -s nullglob
packages=("$bundle_dir"/*.deb)
if (( ${#packages[@]} != 1 )); then
  printf 'Expected exactly one .deb in %s; found %d\n' "$bundle_dir" "${#packages[@]}" >&2
  printf '%s\n' "${packages[@]}" >&2
  exit 1
fi

deb="${packages[0]}"
architecture="$(dpkg-deb --field "$deb" Architecture)"
depends="$(dpkg-deb --field "$deb" Depends)"
printf 'Package: %s\nVersion: %s\nArchitecture: %s\nDepends: %s\n' \
  "$(dpkg-deb --field "$deb" Package)" \
  "$(dpkg-deb --field "$deb" Version)" \
  "$architecture" "$depends" | tee "$evidence_dir/package-fields.txt"
[[ "$architecture" == arm64 ]]
grep -Eq 'libgtk-3-0(t64)?([[:space:]]|,|$)' <<< "$depends"
grep -Eq 'libwebkit2gtk-4\.1-0([[:space:]]|,|$)' <<< "$depends"
dpkg-deb --info "$deb" | tee "$evidence_dir/package-info.txt"

package_root="$evidence_dir/extracted"
mkdir -p "$package_root"
dpkg-deb --extract "$deb" "$package_root"
app_binary="$package_root/usr/bin/bench_helloworld"
test -x "$app_binary"
file "$app_binary" | tee "$evidence_dir/app-file.txt"
readelf -h "$app_binary" | tee "$evidence_dir/app-elf-header.txt"
grep -Eq 'Class:[[:space:]]+ELF64' "$evidence_dir/app-elf-header.txt"
grep -Eq 'Machine:[[:space:]]+AArch64' "$evidence_dir/app-elf-header.txt"
readelf -l "$app_binary" > "$evidence_dir/app-program-headers.txt"
grep -Fq '/lib/ld-linux-aarch64.so.1' "$evidence_dir/app-program-headers.txt"

desktop_files=("$package_root"/usr/share/applications/*.desktop)
if (( ${#desktop_files[@]} == 0 )); then
  echo "Debian package contains no desktop entry" >&2
  exit 1
fi
printf '%s\n' "${desktop_files[@]}" | tee "$evidence_dir/desktop-files.txt"
cp -- "$deb" "$evidence_dir/"
