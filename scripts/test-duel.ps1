# Runs every headless duel scenario and writes logs to tests/records/latest/.
#   tests/duel/*.duel           must print PASS
#   tests/duel/negative/*.duel  must FAIL with the text given in its "# expect-fail:" line
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
    $scenarios = @(Get-ChildItem tests/duel -Filter *.duel) + @(Get-ChildItem tests/duel/negative -Filter *.duel)
    foreach ($s in $scenarios) {
        $rel = Resolve-Path -Relative $s.FullName
        $negative = $s.Directory.Name -eq 'negative'
        $output = & $exe --scripts third_party/CardScripts --db third_party/BabelCDB/cards.cdb $rel 2>&1 | Out-String
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
