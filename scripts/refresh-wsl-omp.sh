#!/usr/bin/env bash
set -euo pipefail

if (( $# != 0 )); then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
for tool in powershell.exe cmd.exe wslpath python3 node npm sha256sum; do
  if ! command -v "$tool" >/dev/null; then
    printf 'Required command not found in WSL: %s\n' "$tool" >&2
    exit 1
  fi
done

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
win_prefix=$(powershell.exe -NoProfile -NonInteractive -Command '[Console]::Write((Join-Path $env:LOCALAPPDATA "LCU-OMP-WSL"))')
prefix=$(wslpath -u "$win_prefix")
if [[ ! -f "$prefix/.lcu-install" || ! -f "$prefix/current.json" ]]; then
  printf 'No existing LCU-OMP-WSL installation at %s. This command only refreshes an existing installation.\n' "$win_prefix" >&2
  exit 1
fi

# Run the Windows installer from a Windows-local directory, not a WSL UNC path.
win_temp=$(powershell.exe -NoProfile -NonInteractive -Command '[Console]::Write($env:TEMP)')
stage=$(mktemp -d "$(wslpath -u "$win_temp")/lcu-omp-refresh.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT

python3 "$source_dir/scripts/build_bundle.py" --platform windows --output "$stage"
cd -- "$stage"
sha256sum -c -- lcu-*-windows-x64.zip.sha256
python3 -m zipfile -e lcu-*-windows-x64.zip .
cd -- lcu-*-windows-x64
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$PWD/scripts/install.ps1")" --runtime-only --in-place --prefix "$win_prefix"

cd -- "$prefix"
WSLENV=CODEX_HOME/w CODEX_HOME="$win_prefix\\codex-home" cmd.exe /d /c lcu.cmd doctor --non-interactive
