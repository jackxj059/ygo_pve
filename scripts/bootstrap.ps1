# Restores third-party checkouts and build tools pinned in third_party/versions.lock.json.
# Safe to re-run: existing checkouts with local changes are reported, never reset.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -Raw (Join-Path $root 'third_party/versions.lock.json') | ConvertFrom-Json

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)" }
}

foreach ($repo in $lock.repositories) {
    $dir = Join-Path $root $repo.path
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        Write-Host "[clone] $($repo.name) <- $($repo.remote)"
        Invoke-Git clone $repo.remote $dir
    }
    $dirty = & git -C $dir status --porcelain --ignore-submodules=dirty
    $head = (& git -C $dir rev-parse HEAD).Trim()
    if ($head -ne $repo.commit) {
        if ($dirty) { throw "$($repo.name): local changes present and HEAD $head != locked $($repo.commit). Commit/stash them first." }
        Write-Host "[checkout] $($repo.name) $($repo.commit)"
        & git -C $dir cat-file -e "$($repo.commit)^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { Invoke-Git -C $dir fetch origin }
        Invoke-Git -C $dir checkout --quiet --detach $repo.commit
    } elseif ($dirty) {
        Write-Warning "$($repo.name): at locked commit but has local changes (left untouched)."
    } else {
        Write-Host "[ok] $($repo.name) $head"
    }
}

$core = Join-Path $root 'third_party/ygopro-core'
Invoke-Git -C $core submodule update --init --recursive
foreach ($line in $lock.core_submodules) {
    $want = ($line.Trim() -split ' ')[0]
    $path = ($line.Trim() -split ' ')[1]
    $have = (& git -C (Join-Path $core $path) rev-parse HEAD).Trim()
    if ($have -ne $want) { throw "core submodule $path is $have, expected $want" }
    Write-Host "[ok] ygopro-core/$path $have"
}

$downloads = Join-Path $root 'tools/downloads'
New-Item -ItemType Directory -Force $downloads | Out-Null
foreach ($tool in $lock.build_tools) {
    $dest = Join-Path $root $tool.path
    $stamp = Join-Path $dest '.version'
    if ((Test-Path $stamp) -and ((Get-Content -Raw $stamp).Trim() -eq $tool.sha256)) {
        Write-Host "[ok] $($tool.name) $($tool.version)"
        continue
    }
    $zip = Join-Path $downloads ([IO.Path]::GetFileName($tool.url))
    if (-not (Test-Path $zip) -or (Get-FileHash -Algorithm SHA256 $zip).Hash -ne $tool.sha256) {
        Write-Host "[download] $($tool.url)"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object Net.WebClient).DownloadFile($tool.url, $zip)
    }
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash
    if ($hash -ne $tool.sha256) { throw "$($tool.name): SHA256 mismatch ($hash)" }
    Write-Host "[extract] $($tool.name) -> $($tool.path)"
    $tmp = Join-Path $downloads "extract-$($tool.name)"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    New-Item -ItemType Directory $tmp | Out-Null
    # Windows' bundled bsdtar; Expand-Archive breaks on long paths inside the toolchain zip.
    & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "$($tool.name): extracting $zip failed" }
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    # Each archive holds a single top-level folder.
    Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $dest
    Remove-Item -Recurse -Force $tmp
    Set-Content -Path $stamp -Value $tool.sha256 -Encoding ascii
}
Write-Host 'bootstrap complete'
