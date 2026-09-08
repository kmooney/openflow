<#
.SYNOPSIS
  Builds the OpenFlow Windows client.

.DESCRIPTION
  whisper.cpp is compiled from source by whisper-rs, which needs CMake and the
  MSVC C/C++ toolchain. Neither is on PATH in an ordinary shell, and the
  combination that works is specific enough to be worth scripting rather than
  documenting:

    * the developer environment from vcvars64.bat, so cl.exe, the linker and
      the Windows SDK headers are all findable;
    * the Ninja generator rather than the Visual Studio one. The VS generator
      fails with "No CMAKE_C_COMPILER could be found" unless it is run from an
      environment it can introspect, and Ninja simply uses the cl.exe that
      vcvars just put on PATH.

  Both CMake and Ninja ship inside Visual Studio, so nothing extra is needed
  beyond VS with the C++ workload.

.PARAMETER Configuration
  Debug or Release. Release by default: whisper on a debug build is slow enough
  to feel broken.

.PARAMETER Gpu
  none (default), cuda, or vulkan. Both GPU backends need their own SDK
  installed; CPU inference is the supported path.

.PARAMETER Test
  Run the test suite instead of building the executable.

.EXAMPLE
  .\build-windows.ps1
  .\build-windows.ps1 -Test
  .\build-windows.ps1 -Gpu cuda
#>
[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')] [string] $Configuration = 'Release',
  [ValidateSet('none', 'cuda', 'vulkan')] [string] $Gpu = 'none',
  [switch] $Test
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-VisualStudio {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    $found = & $vswhere -latest -products * `
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
      -property installationPath 2>$null
    if ($found) { return $found }
  }
  # vswhere is missing on some installs; fall back to the usual locations.
  $candidates = @(
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Enterprise",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Professional",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Community",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools"
  )
  foreach ($c in $candidates) {
    if (Test-Path "$c\VC\Auxiliary\Build\vcvars64.bat") { return $c }
  }
  return $null
}

$vs = Find-VisualStudio
if (-not $vs) {
  throw "Visual Studio with the C++ workload was not found. Install it (or the Build Tools) and try again."
}

$vcvars = "$vs\VC\Auxiliary\Build\vcvars64.bat"
$cmake  = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
$ninja  = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
foreach ($p in @($vcvars, "$cmake\cmake.exe", "$ninja\ninja.exe")) {
  if (-not (Test-Path $p)) { throw "Missing $p. Install the C++ CMake tools for Windows component." }
}

$cargoArgs = @()
if ($Test) { $cargoArgs += 'test' } else { $cargoArgs += 'build' }
if ($Configuration -eq 'Release') { $cargoArgs += '--release' }
if ($Gpu -ne 'none') { $cargoArgs += @('--features', $Gpu) }

Write-Host "OpenFlow: cargo $($cargoArgs -join ' ')  [$vs]"

# Run inside cmd so vcvars64.bat can set the environment for cargo. The
# generator is quoted with no trailing space: CMake rejects "Ninja " outright,
# and the error it prints is a list of every generator it knows rather than
# anything about whitespace.
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$command = @(
  "set `"PATH=$installer;%PATH%`"",
  "`"$vcvars`" >nul",
  "set `"PATH=$cmake;$ninja;%PATH%`"",
  "set `"CMAKE_GENERATOR=Ninja`"",
  "cd /d `"$root`"",
  "cargo $($cargoArgs -join ' ')"
) -join ' && '

# vcvars and cargo both write progress to stderr. Under ErrorActionPreference
# 'Stop' PowerShell turns any of it into a terminating error, which would abort
# a build that is going perfectly well; the exit code is the real answer.
$ErrorActionPreference = 'Continue'
cmd /c $command
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $Test) {
  $exe = Join-Path $root "target\$($Configuration.ToLower())\openflow.exe"
  Write-Host ""
  Write-Host "Built $exe"
  Write-Host "Run it, then hold Ctrl+Shift and speak."
}
