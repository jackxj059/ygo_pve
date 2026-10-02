# Builds build/ocgcore.dll (ygopro-core + Lua) and build/duel_harness.exe with the
# pinned llvm-mingw toolchain. Run scripts/bootstrap.ps1 first.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cxx = Join-Path $root 'tools/llvm-mingw/bin/x86_64-w64-mingw32-clang++.exe'
$cc = Join-Path $root 'tools/llvm-mingw/bin/x86_64-w64-mingw32-clang.exe'
foreach ($tool in $cxx, $cc) {
    if (-not (Test-Path $tool)) { throw "missing $tool - run scripts/bootstrap.ps1 first" }
}
$core = Join-Path $root 'third_party/ygopro-core'
$lua = Join-Path $core 'lua'
$sqlite = Join-Path $root 'tools/sqlite'
$out = Join-Path $root 'build'
$obj = Join-Path $out 'obj'
New-Item -ItemType Directory -Force $obj | Out-Null

# Compiles each (compiler, source, args) job in parallel; throws on the first failure.
function Invoke-Compile($jobs) {
    $running = @()
    foreach ($job in $jobs) {
        while (@($running | Where-Object { -not $_.HasExited }).Count -ge [Environment]::ProcessorCount) {
            Start-Sleep -Milliseconds 100
        }
        $log = Join-Path $obj ([IO.Path]::GetFileName($job.Out) + '.log')
        $quoted = $job.Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $p = Start-Process -FilePath $job.Exe -ArgumentList $quoted -NoNewWindow -PassThru -RedirectStandardError $log
        $null = $p.Handle # PowerShell 5.1 only reports ExitCode if the handle was opened
        $p | Add-Member NoteProperty Job $job
        $p | Add-Member NoteProperty Log $log
        $running += $p
    }
    $running | ForEach-Object { $_.WaitForExit() }
    $failed = $running | Where-Object { $_.ExitCode -ne 0 }
    foreach ($p in $running) {
        $text = Get-Content -Raw $p.Log
        if ($text -and $p.ExitCode -ne 0) { Write-Host $text }
    }
    if ($failed) { throw "compile failed: $(($failed | ForEach-Object { $_.Job.Src }) -join ', ')" }
}

$common = @('-O2', '-g', '-DNDEBUG', '-DWIN32', '-D_WIN32', '-DNOMINMAX', '-DUNICODE', '-D_UNICODE')
$jobs = @()

# Lua is compiled as C++ with the core's config header forced in (see lua/meson.build).
$luaSources = 'lapi lauxlib lbaselib lcode lctype ldebug ldo ldump lfunc lgc liolib llex lmathlib lmem lobject lopcodes lparser lstate lstring lstrlib ltable ltablib ltm lundump lvm lzio' -split ' '
foreach ($name in $luaSources) {
    $o = Join-Path $obj "lua_$name.o"
    $jobs += @{ Exe = $cxx; Src = "lua/src/$name.c"; Out = $o; Args = $common + @('-std=c++17', '-x', 'c++', '-w', '-include', (Join-Path $lua 'luaconf-customize.h'), '-c', (Join-Path $lua "src/$name.c"), '-o', $o) }
}
$coreSources = 'card duel effect field interpreter libcard libdebug libduel libeffect libgroup ocgapi operations playerop processor processor_visit scriptlib' -split ' '
foreach ($name in $coreSources) {
    $o = Join-Path $obj "core_$name.o"
    $jobs += @{ Exe = $cxx; Src = "$name.cpp"; Out = $o; Args = $common + @('-std=c++17', '-fno-rtti', '-fvisibility=hidden', '-DOCGCORE_EXPORT_FUNCTIONS', '-Wall', '-Wextra', '-Wno-unused-parameter', '-isystem', (Join-Path $lua 'src'), '-c', (Join-Path $core "$name.cpp"), '-o', $o) }
}
$sqliteObj = Join-Path $obj 'sqlite3.o'
$jobs += @{ Exe = $cc; Src = 'sqlite3.c'; Out = $sqliteObj; Args = $common + @('-w', '-DSQLITE_OMIT_LOAD_EXTENSION', '-DSQLITE_THREADSAFE=0', '-c', (Join-Path $sqlite 'sqlite3.c'), '-o', $sqliteObj) }
$harnessObj = Join-Path $obj 'duel_harness.o'
$jobs += @{ Exe = $cxx; Src = 'duel_harness/main.cpp'; Out = $harnessObj; Args = $common + @('-std=c++17', '-Wall', '-Wextra', '-I', $core, '-I', $sqlite, '-c', (Join-Path $root 'native/duel_harness/main.cpp'), '-o', $harnessObj) }

Write-Host "[compile] $($jobs.Count) translation units"
Invoke-Compile $jobs

$dll = Join-Path $out 'ocgcore.dll'
$implib = Join-Path $out 'libocgcore.dll.a'
$coreObjs = $jobs | Where-Object { $_.Out -match '\\(lua|core)_[^\\]+\.o$' } | ForEach-Object { $_.Out }
Write-Host '[link] ocgcore.dll'
& $cxx -shared -static -o $dll @coreObjs "-Wl,--out-implib,$implib"
if ($LASTEXITCODE -ne 0) { throw 'linking ocgcore.dll failed' }

$exe = Join-Path $out 'duel_harness.exe'
Write-Host '[link] duel_harness.exe'
& $cxx -static -o $exe $harnessObj $sqliteObj $implib
if ($LASTEXITCODE -ne 0) { throw 'linking duel_harness.exe failed' }

Write-Host "build complete: $dll, $exe"
