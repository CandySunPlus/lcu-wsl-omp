#!/usr/bin/env bash
set -euo pipefail

if (( $# != 0 )); then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
for tool in powershell.exe cmd.exe wslpath python3 node npm sha256sum omp flock; do
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

# Serialize refresh and pruning for all omp profiles in this WSL account.
data="$HOME/.local/share/lcu/omp-wsl"
mkdir -p -m 700 -- "$data"
exec 9>"$data/.refresh.lock"
if ! flock -n 9; then
  printf 'Another WSL omp refresh is running.\\n' >&2
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

cd -- "$source_dir"
node --input-type=module - "$prefix" "$win_prefix" "$(command -v cmd.exe)" "$data" <<'NODE'
import { cpSync, existsSync, mkdtempSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { configureOmp } from './lcu/harness_setup.mjs';

const [prefix, windowsPrefix, cmd, data] = process.argv.slice(2);
const generation = /^\d+\.\d+\.\d+-[0-9a-f]{12}$/;
const { release } = JSON.parse(readFileSync(join(prefix, 'current.json'), 'utf8'));
if (typeof release !== 'string' || !generation.test(release)) {
  throw new Error('Invalid LCU-OMP-WSL release pointer.');
}
const selected = join(prefix, 'releases', release);
const { platform, app_source: appSource } = JSON.parse(readFileSync(join(selected, 'installation.json'), 'utf8'));
if (platform !== 'windows' || appSource !== 'store') throw new Error('Expected an in-place Windows LCU release.');

// Keep only the thin LCU adapter code in WSL, independent of Windows release pruning.
const home = homedir();
const adapter = join(data, `windows-${release}`);
if (!existsSync(adapter)) {
  const stage = mkdtempSync(join(data, '.adapter-'));
  try {
    for (const dir of ['adapters', 'lcu']) cpSync(join(selected, dir), join(stage, dir), { recursive: true });
    renameSync(stage, adapter);
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

const command = ['/usr/bin/env', '-C', prefix, 'WSLENV=CODEX_HOME/w', `CODEX_HOME=${windowsPrefix}\\codex-home`, cmd, '/d', '/c', 'lcu.cmd', '--chrome'];
configureOmp(home, command, adapter, { scope: 'user', env: process.env });
console.log(`LCU and Chrome mode refreshed for the selected omp profile (${process.env.OMP_PROFILE || 'default'}). Restart omp.`);
NODE

# The documented update procedure closes omp first. If a Windows process is
# still using this prefix, defer cleanup rather than remove a live release.
if ! powershell.exe -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $prefix = Join-Path $env:LOCALAPPDATA "LCU-OMP-WSL"
  $live = Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and ($_.ExecutablePath -like "$prefix\*" -or $_.CommandLine -like "*$prefix\*")
  }
  if ($live) { exit 1 }
'; then
  printf 'LCU refreshed; skipped cleanup because the Windows runtime may still be in use. Close other LCU sessions before the next refresh.\n' >&2
  exit 0
fi

cd -- "$prefix"
cmd.exe /d /c lcu.cmd prune --keep 2 --yes

node --input-type=module - "$prefix" "$data" <<'NODE'
import { readdirSync, readFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const [prefix, data] = process.argv.slice(2);
const kept = new Set(readdirSync(join(prefix, 'releases')).map(name => `windows-${name}`));
const profiles = join(homedir(), '.local/share/lcu/omp');
// Other omp profiles can still import an adapter older than the retained Windows releases.
for (const entry of readdirSync(profiles, { withFileTypes: true })) {
  if (!/^user-[0-9a-f]{16}$/.test(entry.name)) continue;
  const wrapper = readFileSync(join(profiles, entry.name, 'index.ts'), 'utf8');
  for (const name of wrapper.match(/\bwindows-\d+\.\d+\.\d+-[0-9a-f]{12}\b/g) ?? []) kept.add(name);
}
for (const entry of readdirSync(data, { withFileTypes: true })) {
  if (!entry.isDirectory() || !/^windows-\d+\.\d+\.\d+-[0-9a-f]{12}$/.test(entry.name) || kept.has(entry.name)) continue;
  rmSync(join(data, entry.name), { recursive: true });
  console.log(`Removed unused WSL adapter ${entry.name}`);
}
NODE
