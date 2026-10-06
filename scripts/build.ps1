# Builds build/ocgcore.dll (ygopro-core + Lua), build/duel_harness.exe and
# build/battle_tests.exe with the pinned llvm-mingw toolchain. Run scripts/bootstrap.ps1 first.
# The core is compiled from a copy (build/core-src) with patches/ygopro-core/*.patch
# applied, so the third_party checkout itself stays at the clean locked commit.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cxx = Join-Path $root 'tools/llvm-mingw/bin/x86_64-w64-mingw32-clang++.exe'
$cc = Join-Path $root 'tools/llvm-mingw/bin/x86_64-w64-mingw32-clang.exe'
foreach ($tool in $cxx, $cc) {
    if (-not (Test-Path $tool)) { throw "missing $tool - run scripts/bootstrap.ps1 first" }
}
$sqlite = Join-Path $root 'tools/sqlite'
$out = Join-Path $root 'build'
$obj = Join-Path $out 'obj'
New-Item -ItemType Directory -Force $obj | Out-Null

$core = Join-Path $out 'core-src'
if (Test-Path $core) { Remove-Item -Recurse -Force $core }
New-Item -ItemType Directory $core | Out-Null
$upstream = Join-Path $root 'third_party/ygopro-core'
Get-ChildItem $upstream -Exclude '.git' | Copy-Item -Destination $core -Recurse
Push-Location $root
try {
    foreach ($patch in Get-ChildItem (Join-Path $root 'patches/ygopro-core') -Filter *.patch | Sort-Object Name) {
        Write-Host "[patch] $($patch.Name)"
        & git apply --unsafe-paths --directory=build/core-src $patch.FullName
        if ($LASTEXITCODE -ne 0) { throw "patch $($patch.Name) does not apply to the locked ygopro-core" }
    }
} finally {
    Pop-Location
}
$lua = Join-Path $core 'lua'

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
# Battle module (shared by every host) and the two test programs that use it.
$battle = Join-Path $root 'native/battle'
$appSources = [ordered]@{ battle = 'battle/battle.cpp'; deck = 'battle/deck.cpp'; duel_harness = 'duel_harness/main.cpp'; battle_tests = 'battle_tests/main.cpp' }
$appObj = @{}
foreach ($name in $appSources.Keys) {
    $o = Join-Path $obj "app_$name.o"
    $appObj[$name] = $o
    $jobs += @{ Exe = $cxx; Src = $appSources[$name]; Out = $o; Args = $common + @('-std=c++17', '-Wall', '-Wextra', '-I', $core, '-I', $sqlite, '-I', $battle, '-isystem', (Join-Path $lua 'src'), '-c', (Join-Path $root "native/$($appSources[$name])"), '-o', $o) }
}

Write-Host "[compile] $($jobs.Count) translation units"
Invoke-Compile $jobs

$dll = Join-Path $out 'ocgcore.dll'
$implib = Join-Path $out 'libocgcore.dll.a'
$coreObjs = $jobs | Where-Object { $_.Out -match '\\(lua|core)_[^\\]+\.o$' } | ForEach-Object { $_.Out }
Write-Host '[link] ocgcore.dll'
& $cxx -shared -static -o $dll @coreObjs "-Wl,--out-implib,$implib"
if ($LASTEXITCODE -ne 0) { throw 'linking ocgcore.dll failed' }

# The battle module reads enemy definitions with its own Lua state, so the programs link their
# own copy of Lua (ocgcore.dll does not export the Lua API).
$luaObjs = $coreObjs | Where-Object { $_ -match '\\lua_[^\\]+\.o$' }
foreach ($name in 'duel_harness', 'battle_tests') {
    Write-Host "[link] $name.exe"
    & $cxx -static -o (Join-Path $out "$name.exe") $appObj[$name] $appObj.battle $appObj.deck $sqliteObj @luaObjs $implib
    if ($LASTEXITCODE -ne 0) { throw "linking $name.exe failed" }
}

# Godot GDExtension: battle module + core linked statically into one DLL, built through
# godot-cpp's SCons setup so compiler flags match the godot-cpp library.
$static = Join-Path $out 'libygo_battle.a'
if (Test-Path $static) { Remove-Item $static }
Write-Host '[archive] libygo_battle.a'
& (Join-Path $root 'tools/llvm-mingw/bin/llvm-ar.exe') rcs $static $appObj.battle $appObj.deck $sqliteObj @coreObjs
if ($LASTEXITCODE -ne 0) { throw 'creating libygo_battle.a failed' }
$python = Join-Path $root 'tools/python/python.exe'
if (-not (Test-Path $python)) { throw "missing $python - run scripts/bootstrap.ps1 first" }
Write-Host '[scons] ygo_battle GDExtension (first run also builds godot-cpp, several minutes)'
$env:PYTHONPATH = Join-Path $root 'tools/scons'
& $python -c 'from SCons.Script import main; main()' -Q -C (Join-Path $root 'native/gdextension') `
    platform=windows arch=x86_64 use_mingw=yes use_llvm=yes "mingw_prefix=$(Join-Path $root 'tools/llvm-mingw')" `
    api_version=4.7 target=template_debug disable_exceptions=no lto=none "-j$([Environment]::ProcessorCount)"
if ($LASTEXITCODE -ne 0) { throw 'building the GDExtension failed' }

Write-Host "build complete: $out, game/addons/ygo_battle/bin"
