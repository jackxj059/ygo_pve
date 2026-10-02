# Downloads card images from YGOPRODeck into third_party/card_images/<kind>/<code>.jpg.
# YGOPRODeck asks clients to download each image once and host it themselves, and
# blacklists IPs that pull images at high rates: this script is sequential, waits
# between requests and skips files it already has, so it is safe to re-run/resume.
#   -Kind full     card images (default)
#   -Kind cropped  artwork only
[CmdletBinding()]
param(
    [ValidateSet('full', 'cropped')][string]$Kind = 'full',
    [int]$DelayMs = 100
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$base = Join-Path $root 'third_party/card_images'
$dest = Join-Path $base $Kind
New-Item -ItemType Directory -Force $dest | Out-Null
$remoteDir = @{ full = 'cards'; cropped = 'cards_cropped' }[$Kind]

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$client = New-Object Net.WebClient
$client.Proxy = $null # proxy auto-detection costs seconds per request
$client.Headers.Add('User-Agent', 'YGO_PVE card image fetch (personal, one-time download)')

$infoPath = Join-Path $base 'cardinfo.json'
Write-Host '[list] https://db.ygoprodeck.com/api/v7/cardinfo.php'
$client.DownloadFile('https://db.ygoprodeck.com/api/v7/cardinfo.php', $infoPath)
# Regex instead of ConvertFrom-Json: the 20 MB response is slow to parse in PowerShell 5.1.
$ids = [regex]::Matches((Get-Content -Raw $infoPath), '"image_url":"https://images\.ygoprodeck\.com/images/cards/(\d+)\.jpg"') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Write-Host "[list] $($ids.Count) images"

$downloaded = 0; $skipped = 0; $failed = @()
$i = 0
foreach ($id in $ids) {
    $i++
    $file = Join-Path $dest "$id.jpg"
    if ((Test-Path $file) -and (Get-Item $file).Length -gt 0) { $skipped++; continue }
    $ok = $false
    foreach ($attempt in 1..3) {
        try {
            $client.DownloadFile("https://images.ygoprodeck.com/images/$remoteDir/$id.jpg", "$file.part")
            Move-Item -Force "$file.part" $file
            $ok = $true
            break
        } catch {
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    if ($ok) { $downloaded++ } else { $failed += $id; Remove-Item -ErrorAction SilentlyContinue "$file.part" }
    if ($i % 500 -eq 0) { Write-Host "[progress] $i/$($ids.Count) downloaded=$downloaded skipped=$skipped failed=$($failed.Count)" }
    Start-Sleep -Milliseconds $DelayMs
}

$failed | Set-Content -Encoding ascii (Join-Path $base "failed-$Kind.txt")
@(
    "source: https://images.ygoprodeck.com/images/$remoteDir/<code>.jpg (list: db.ygoprodeck.com/api/v7/cardinfo.php)"
    "last_run_utc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    "kind: $Kind, listed: $($ids.Count), downloaded: $downloaded, already_present: $skipped, failed: $($failed.Count)"
) | Set-Content -Encoding ascii (Join-Path $base "source-$Kind.txt")
Write-Host "done: downloaded=$downloaded skipped=$skipped failed=$($failed.Count) -> $dest"
if ($failed.Count) { exit 1 }
