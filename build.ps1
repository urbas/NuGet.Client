[CmdletBinding(DefaultParameterSetName='RegularBuild')]
param (
    [ValidateSet("debug", "release")]
    [string]$Configuration="debug",
    [ValidateSet("Release","rtm", "rc", "beta", "local")]
    [string]$ReleaseLabel="local",
    [string]$BuildNumber,
    [Parameter(ParameterSetName='RegularBuild')]
    [switch]$SkipTests,
    [switch]$SkipRestore,
    [switch]$CleanCache,
    [switch]$SkipILMerge,
    [switch]$DelaySign,
    [string]$MSPFXPath,
    [string]$NuGetPFXPath,
    [switch]$SkipXProj,
    [switch]$SkipSubModules,
    [switch]$SkipCSProj,
    [Parameter(ParameterSetName='FastBuild')]
    [switch]$Fast
)

. "$PSScriptRoot\build\common.ps1"

$RunTests = (-not $SkipTests) -and (-not $Fast)

$startTime = [DateTime]::UtcNow

Trace-Log "Build started at $startTime"
Trace-Log

# Move to the script directory
pushd $NuGetClientRoot

if (-not $SkipSubModules) {
    Update-Submodules
}

Clear-Artifacts

if ($CleanCache) {
    Clear-PackageCache
}

Install-NuGet

# Restoring tools required for build
if (-not $SkipRestore) {
    Restore-SolutionPackages
}

Install-DNVM
Install-DNX

if ($DelaySign)
{
    Enable-DelayedSigning
}

$BuildNumber = Get-BuildNumber $BuildNumber

if (-not $SkipXProj) {
    ## Building all XProj projects
    Invoke-DnuPack

    if ($RunTests) {
        Test-XProj
    }
}

## Building the Tooling solution
if (-not $SkipCSproj)
{
    Invoke-CSproj
}

if ((-not $SkipILMerge) -and (-not $SkipCSProj))
{
    Invoke-ILMerge
}

## Calculating Build time
$endTime = [DateTime]::UtcNow
$diff = [math]::Round(($endTime - $startTime).TotalMinutes, 4)

Trace-Log
Trace-Log "Build ended at $endTime"
Trace-Log "Build took $diff minutes"

popd