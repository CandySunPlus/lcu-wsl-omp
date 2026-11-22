#!/usr/bin/env bash
set -euo pipefail

if (( $# != 0 )); then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
for tool in powershell.exe cmd.exe wslpath node omp; do
  if ! command -v "$tool" >/dev/null; then
    printf 'Required command not found in WSL: %s\n' "$tool" >&2
    exit 1
  fi
done

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
win_prefix=$(powershell.exe -NoProfile -NonInteractive -Command '[Console]::Write((Join-Path $env:LOCALAPPDATA "LCU-OMP-WSL"))')
prefix=$(wslpath -u "$win_prefix")
if [[ ! -f "$prefix/current.json" || ! -f "$prefix/lcu.cmd" ]]; then
  printf 'No existing LCU-OMP-WSL installation at %s.\n' "$win_prefix" >&2
  exit 1
fi

cd -- "$source_dir"
node --input-type=module - "$prefix" "$win_prefix" "$(command -v cmd.exe)" <<'NODE'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { configureOmp } from './lcu/harness_setup.mjs';

const [prefix, windowsPrefix, cmd] = process.argv.slice(2);
const { release } = JSON.parse(readFileSync(join(prefix, 'current.json'), 'utf8'));
if (typeof release !== 'string' || !/^\d+\.\d+\.\d+-[0-9a-f]{12}$/.test(release)) {
  throw new Error('Invalid LCU-OMP-WSL release pointer.');
}
const selected = join(prefix, 'releases', release);
const { platform, app_source: appSource } = JSON.parse(readFileSync(join(selected, 'installation.json'), 'utf8'));
if (platform !== 'windows' || appSource !== 'store') throw new Error('Run the in-place Windows LCU installer first.');

// Keep only the thin LCU adapter code in WSL, independent of Windows release pruning.
const home = homedir();
const data = join(home, '.local/share/lcu/omp-wsl');
const adapter = join(data, `windows-${release}`);
if (!existsSync(adapter)) {
  mkdirSync(data, { recursive: true, mode: 0o700 });
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
console.log(`Chrome mode enabled for the selected omp profile (${process.env.OMP_PROFILE || 'default'}). Restart omp.`);
NODE
