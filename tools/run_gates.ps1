# Meridian Bay — canonical regression gate runner (Task 8 prep, 2026-10-22).
#
# This is a SUPERSET of the historical Task 7C.2 runner
# (scratch_7c_2\run_gates.ps1, left untouched as evidence). It runs every
# existing gate plus two new ones:
#
#   gate_validate : static validation (scripts parse, scenes load, groups and
#                   required node paths resolve)
#   gate_e2e      : end-to-end playability run (spawn -> interact -> van ->
#                   HB-01 delivery -> save -> load)
#   gate_npc_contracts : Task 8 structural contracts (NPC scripts, data files,
#                   waypoint graph keep-out, pedestrian collision config)
#   gate_npc      : Task 8 NPC behaviour test (spawn, grounding, bounds,
#                   locomotion, waypoint arrival, read-only guarantees)
#   gate_npc_perf : Task 8 NPC performance probe (rendered, physics/draw/memory
#                   deltas against the proposal budgets)
#
# No gate is disabled, weakened or bypassed. Every gate keeps its original
# script, thresholds and assertions.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\run_gates.ps1 -OutDir <name>
#
# Logs and summary are written under <project>\reports\<OutDir> (B:).
# The render gate needs a display/GPU (it is NOT run headless).
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [switch]$SkipRender
)
$ErrorActionPreference = 'Continue'
$proj = 'B:\Study\Projects\VibeCoding\GTA'
$exe = 'B:\Engines\Godot\Godot_v4.7.2-stable_win64_console.exe'
$dest = Join-Path $proj "reports\$OutDir"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$gates = @(
  @{ name = 'gate_validate'; args = @('--headless', '--path', $proj, '--script', 'res://tools/validate_scripts.gd') },
  @{ name = 'gate_smoke';    args = @('--headless', '--path', $proj, '--script', 'res://tools/smoke_test_task1.gd') },
  @{ name = 'gate_interact'; args = @('--headless', '--path', $proj, '--script', 'res://tools/interact_test_task2.gd') },
  @{ name = 'gate_vehicle';  args = @('--headless', '--path', $proj, '--script', 'res://tools/vehicle_test_task3.gd') },
  @{ name = 'gate_mission';  args = @('--headless', '--path', $proj, '--script', 'res://tools/mission_test_task4.gd') },
  @{ name = 'gate_save';     args = @('--headless', '--path', $proj, '--script', 'res://tools/save_test_task5.gd') },
  @{ name = 'gate_e2e';      args = @('--headless', '--path', $proj, '--script', 'res://tools/playability_e2e.gd') },
  @{ name = 'gate_audit';    args = @('--headless', '--path', $proj, '--script', 'res://tools/asset_audit.gd') },
  @{ name = 'contracts';     args = @('--headless', '--path', $proj, '--script', 'res://scratch_7b_8/contracts.gd') },
  @{ name = 'gate_npc_contracts'; args = @('--headless', '--path', $proj, '--script', 'res://tools/npc_contracts_task8.gd') },
  @{ name = 'gate_npc';    args = @('--headless', '--path', $proj, '--script', 'res://tools/npc_test_task8.gd') }
)
if (-not $SkipRender) {
  $gates = @(
    @{ name = 'gate_render'; args = @('--path', $proj, '--resolution', '1280x720', '--script', 'res://tools/render_check_task1.gd') },
    @{ name = 'gate_npc_perf'; args = @('--path', $proj, '--resolution', '1280x720', '--script', 'res://tools/npc_perf_task8.gd', '--', '--seconds=6', '--cap=0') }
  ) + $gates
}

$summary = @()
$failed = 0
foreach ($g in $gates) {
  $log = Join-Path $dest ($g.name + '.log')
  $a = $g.args
  & $exe @a *> $log
  $code = $LASTEXITCODE
  # Any engine-level script error in the log fails the gate, even if the
  # harness itself exited 0.
  $scriptErrors = @(Select-String -Path $log -Pattern 'SCRIPT ERROR|Parse Error|Failed to load script' -ErrorAction SilentlyContinue).Count
  $tail = (Get-Content $log | Select-String -Pattern 'RESULT:|CONTRACT-RESULT:|VALIDATE-RESULT:|NPC-PERF-RESULT:|SCRIPT ERROR' | Select-Object -Last 3 | ForEach-Object { $_.Line })
  $ok = ($code -eq 0 -and $scriptErrors -eq 0)
  if (-not $ok) { $failed++ }
  $summary += ("{0,-13} exit={1} script_errors={2} {3} :: {4}" -f $g.name, $code, $scriptErrors, $(if ($ok) { 'PASS' } else { 'FAIL' }), ($tail -join ' || '))
}
$summary += ("TOTAL: {0} gate(s), {1} failed" -f $gates.Count, $failed)
$summary | Set-Content (Join-Path $dest 'summary.txt')
$summary
if ($failed -gt 0) { exit 1 }
exit 0
