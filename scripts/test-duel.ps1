# Runs the battle module self-checks and every headless duel scenario, writing
# logs to tests/records/latest/.
#   build/battle_tests.exe      must print PASS
#   tests/duel/*.duel           must print PASS
#   tests/duel/prompts/*.duel   must print PASS (one real-card scenario per prompt type)
#   tests/duel/enemy/*.duel     must print PASS (enemy prototype; enemies from game/data/enemies)
#   tests/duel/negative/*.duel  must FAIL with the text given in its "# expect-fail:" line
#   game/tests/smoke_test.gd    Godot (headless) loads the GDExtension and plays a duel: must print PASS
# Exit code is non-zero if any scenario does not behave as expected.
[CmdletBinding()]
param([switch]$Build)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Build -or -not (Test-Path (Join-Path $root 'build/duel_harness.exe'))) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}
$exe = Join-Path $root 'build/duel_harness.exe'
$records = Join-Path $root 'tests/records/latest'
New-Item -ItemType Directory -Force $records | Out-Null
Get-ChildItem $records -Filter *.log | Remove-Item

Push-Location $root
try {
    $results = @()
    # Battle module self-checks (ydk parsing, prompt lifecycle, shuffling, recreate).
    $output = & (Join-Path $root 'build/battle_tests.exe') 2>&1 | Out-String
    $code = $LASTEXITCODE
    $output | Set-Content -Encoding utf8 (Join-Path $records 'battle_tests.log')
    $status = if ($code -eq 0 -and $output.TrimEnd().EndsWith('PASS')) { 'ok' } else { 'UNEXPECTED' }
    Write-Host ("[{0}] build/battle_tests.exe (exit {1})" -f $status, $code)
    if ($status -ne 'ok') { Write-Host $output }
    $results += [pscustomobject]@{ Scenario = 'build/battle_tests.exe'; Exit = $code; Result = $status }

    $scenarios = @(Get-ChildItem tests/duel -Filter *.duel) + @(Get-ChildItem tests/duel/prompts -Filter *.duel) +
        @(Get-ChildItem tests/duel/ap -Filter *.duel) + @(Get-ChildItem tests/duel/enemy -Filter *.duel) +
        @(Get-ChildItem tests/duel/negative -Filter *.duel)
    foreach ($s in $scenarios) {
        $rel = Resolve-Path -Relative $s.FullName
        $negative = $s.Directory.Name -eq 'negative'
        $output = & $exe --scripts third_party/CardScripts --db third_party/BabelCDB/cards.cdb --enemies game/data/enemies $rel 2>&1 | Out-String
        $code = $LASTEXITCODE
        $output | Set-Content -Encoding utf8 (Join-Path $records ($s.BaseName + '.log'))
        if ($negative) {
            $want = (Select-String -Path $s.FullName -Pattern '^# expect-fail: (.+)$').Matches[0].Groups[1].Value.Trim()
            $ok = $code -eq 1 -and $output.Contains("FAIL: ") -and $output.Contains($want)
        } else {
            $ok = $code -eq 0 -and $output.TrimEnd().EndsWith('PASS')
        }
        $status = if ($ok) { 'ok' } else { 'UNEXPECTED' }
        Write-Host ("[{0}] {1} (exit {2})" -f $status, $rel, $code)
        if (-not $ok) { Write-Host $output }
        $results += [pscustomobject]@{ Scenario = $rel; Exit = $code; Result = $status }
    }
    # Godot (headless): the GDExtension loads and GDScript drives duels, the screen and the
    # building rules. A script that fails to compile never calls quit(), so each run has a timeout.
    $godot = Join-Path $root 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'
    & $godot --headless --path game --import 2>&1 | Out-Null
    foreach ($test in 'smoke_test', 'rules_test') {
        $out = Join-Path $records "godot_$test.log"
        $err = "$out.stderr"
        $p = Start-Process -FilePath $godot -ArgumentList '--headless', '--path', 'game', '--script', "res://tests/$test.gd" `
            -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle
        if (-not $p.WaitForExit(120000)) { $p.Kill(); $code = 'timeout' } else { $code = $p.ExitCode }
        $output = (Get-Content -Raw $out) + (Get-Content -Raw $err)
        Remove-Item $err
        $output | Set-Content -Encoding utf8 $out
        $status = if ($code -eq 0 -and (Get-Content -Raw $out).Contains("`nPASS")) { 'ok' } else { 'UNEXPECTED' }
        Write-Host ("[{0}] game/tests/$test.gd (exit {1})" -f $status, $code)
        if ($status -ne 'ok') { Write-Host $output }
        $results += [pscustomobject]@{ Scenario = "game/tests/$test.gd"; Exit = $code; Result = $status }
    }

    $summary = @(
        "run_at_utc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "harness: build/duel_harness.exe, core: build/ocgcore.dll"
        "card_db: third_party/BabelCDB/cards.cdb, scripts: third_party/CardScripts"
    ) + ($results | ForEach-Object { "$($_.Result) exit=$($_.Exit) $($_.Scenario)" })
    $summary | Set-Content -Encoding utf8 (Join-Path $records 'summary.txt')
    $bad = @($results | Where-Object { $_.Result -ne 'ok' }).Count
    Write-Host "$($results.Count - $bad)/$($results.Count) scenarios behaved as expected"
    if ($bad) { exit 1 }
} finally {
    Pop-Location
}
