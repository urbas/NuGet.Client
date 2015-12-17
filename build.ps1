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

$RunTests = (-not $SkipTests) -and (-not $Fast)

. .\build\common.ps1

###Functions###

## Clean the machine level cache from all package
function CleanCache()
{
    Trace-Log Removing DNX packages

    if (Test-Path $env:userprofile\.dnx\packages)
    {
        rm -r $env:userprofile\.dnx\packages -Force
    }

    Trace-Log Removing .NUGET packages

    if (Test-Path $env:userprofile\.nuget\packages)
    {
        rm -r $env:userprofile\.nuget\packages -Force
    }

    Trace-Log Removing DNU cache

    if (Test-Path $env:localappdata\dnu\cache)
    {
        rm -r $env:localappdata\dnu\cache -Force
    }

    Trace-Log Removing NuGet web cache

    if (Test-Path $env:localappdata\NuGet\v3-cache)
    {
        rm -r $env:localappdata\NuGet\v3-cache -Force
    }

    Trace-Log Removing NuGet machine cache

    if (Test-Path $env:localappdata\NuGet\Cache)
    {
        rm -r $env:localappdata\NuGet\Cache -Force
    }
}

# Restore projects individually
Function Restore-XProj {
    param(
        [parameter(ValueFromPipeline=$True)]
        [string[]]$xprojDir
    )
    Process {
        $projectJsonFile = Join-Path $xprojDir 'project.json'
        $opts = @('restore', $projectJsonFile, '-s', 'https://www.myget.org/F/nuget-volatile/api/v3/index.json', '-s', 'https://api.nuget.org/v3/index.json')

        Trace-Log "Restoring $projectJsonFile"
        Trace-Log "dnu $opts"
        & dnu $opts

        if ($LASTEXITCODE -ne 0)
        {
            throw "Restore failed $projectJsonFile"
        }
    }
}

# Restore in parallel first to speed things up
Function Restore-XProjFast {
    param(
        [string]$xprojDir
    )
    $opts = @('restore', $xprojDir, '--parallel', '--ignore-failed-sources', '-s', 'https://www.myget.org/F/nuget-volatile/api/v3/index.json', '-s', 'https://api.nuget.org/v3/index.json')

    Trace-Log "Restoring $xprojDir"
    Trace-Log "dnu $opts"
    & dnu $opts

    if ($LASTEXITCODE -ne 0)
    {
        throw "Restore failed $xprojDir"
    }
}

## Building XProj projects
function BuildXproj()
{
    ## Setting the DNX build version
    if($ReleaseLabel -ne "Release")
    {
        $env:DNX_BUILD_VERSION="$ReleaseLabel-$BuildNumber"
    }

    # Setting the DNX AssemblyFileVersion
    $env:DNX_ASSEMBLY_FILE_VERSION=$BuildNumber

    $xprojects = Get-ChildItem src -rec -Filter '*.xproj' |`
        %{ Split-Path $_.FullName -Parent } |`
        ?{ -not $_.EndsWith('NuGet.CommandLine.XPlat') } # TODO: Remove this after fixing XPLAT!

    if (-not $SkipRestore)
    {
        if ($Fast)
        {
            Restore-XProjFast src\NuGet.Core
        }
        else
        {
            Trace-Log 'Restoring XProj packages'
            $xprojects | Restore-XProj
        }
    }

    $opts = , 'pack'
    $opts += $xprojects
    $opts += @('--configuration', $Configuration, '--out', $artifacts)

    Trace-Log
    Trace-Log "dnu $opts"
    &dnu $opts

    if ($LASTEXITCODE -ne 0)
    {
        throw "Build failed $ProjectName"
    }

    if ($RunTests)
    {
        # Test assemblies should not be signed
        if (Test-Path Env:\DNX_BUILD_KEY_FILE)
        {
            Remove-Item Env:\DNX_BUILD_KEY_FILE
        }

        if (Test-Path Env:\DNX_BUILD_DELAY_SIGN)
        {
            Remove-Item Env:\DNX_BUILD_DELAY_SIGN
        }

        $xtests = Get-ChildItem test\NuGet.Core.Tests -rec -Filter '*.xproj' |`
            %{ Split-Path $_.FullName -Parent }

        if ($Fast)
        {
            Restore-XProjFast test\NuGet.Core.Tests
        }
        else
        {
            Trace-Log 'Restoring XProj packages'
            $xtests | Restore-XProj
        }

        foreach ($srcDir in $xtests)
        {
            Trace-Log "Running tests in $srcDir"

            pushd $srcDir
            & dnx test
            popd

            if ($LASTEXITCODE -ne 0)
            {
                throw "Tests failed $srcDir"
            }
        }
    }

    ## Copying nupkgs
    Trace-Log "Moving the packages to $nupkgsDir"
    Get-ChildItem $artifacts\*.nupkg -Recurse | % { Move-Item $_ $nupkgsDir }
}

function BuildCSproj()
{
    #Building the microsoft interop package for the test.utility
    $interopLib = ".\lib\Microsoft.VisualStudio.ProjectSystem.Interop"
    & dnu restore $interopLib -s https://www.myget.org/F/nuget-volatile/api/v2/ -s https://www.nuget.org/api/v2/
    & dnu pack $interopLib
    Get-ChildItem $interopLib\*.nupkg -Recurse | % { Move-Item $_ $nupkgsDir }

    # Restore packages for NuGet.Tooling solution
    & $nugetExe restore -msbuildVersion 14 .\NuGet.Clients.sln

    # Build the solution
    & $msbuildExe .\NuGet.Clients.sln /m "/p:Configuration=$Configuration;ReleaseLabel=$ReleaseLabel;BuildNumber=$BuildNumber;RunTests=$RunTests;BuildInParallel=true"

    if ($LASTEXITCODE -ne 0)
    {
        throw "NuGet.Clients.sln Build failed "
    }

    Trace-Log "Copying the Vsix to $artifacts"
    $visxLocation = Join-Path $artifacts "$Configuration\NuGet.Clients\VsExtension"
    Copy-Item $visxLocation\NuGet.Tools.vsix $artifacts
}

function ILMergeNuGet()
{
    $nugetArtifictFolder = Join-Path $artifacts "$Configuration\NuGet.Clients\NuGet.CommandLine"

    pushd $nugetArtifictFolder

    Trace-Log "Creating the ilmerged nuget.exe"
    & $ILMerge NuGet.exe NuGet.Client.dll NuGet.Commands.dll NuGet.Configuration.dll NuGet.ContentModel.dll NuGet.Core.dll NuGet.Credentials.dll NuGet.DependencyResolver.Core.dll NuGet.DependencyResolver.dll NuGet.Frameworks.dll NuGet.LibraryModel.dll NuGet.Logging.dll NuGet.PackageManagement.dll NuGet.Packaging.Core.dll NuGet.Packaging.Core.Types.dll NuGet.Packaging.dll NuGet.ProjectManagement.dll NuGet.ProjectModel.dll NuGet.Protocol.Core.Types.dll NuGet.Protocol.Core.v2.dll NuGet.Protocol.Core.v3.dll NuGet.Repositories.dll NuGet.Resolver.dll NuGet.RuntimeModel.dll NuGet.Versioning.dll Microsoft.Web.XmlTransform.dll Newtonsoft.Json.dll /log:mergelog.txt /out:$artifacts\NuGet.exe

    if ($LASTEXITCODE -ne 0)
    {
        throw "ILMerge failed"
    }

    popd
}

###Functions###

# Move to the script directory
$executingScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
pushd $executingScriptDirectory

$msbuildExe = "${env:ProgramFiles(x86)}\MSBuild\14.0\Bin\msbuild.exe"
$nugetExe = ".nuget\nuget.exe"
$ILMerge = Join-Path $executingScriptDirectory "packages\ILMerge.2.14.1208\tools\ILMerge.exe"
$dnvmLoc = Join-Path $env:USERPROFILE ".dnx\bin\dnvm.cmd"
$nupkgsDir = Join-Path $executingScriptDirectory "nupkgs"
$artifacts = Join-Path $executingScriptDirectory "artifacts"
$startTime = [DateTime]::UtcNow

Trace-Log "Build started at $startTime"
Trace-Log

if ($SkipSubModules -eq $False)
{
    if ((Test-Path -Path "submodules/FileSystem/src") -eq $False)
    {
        Trace-Log "Updating and initializing submodules"
        & git submodule update --init
    }
    else
    {
        Trace-Log "Updating submodules"
        & git submodule update
    }
}

# Download NuGet.exe if missing
if ((Test-Path $nugetExe) -eq $False)
{
    Trace-Log "Downloading nuget.exe"
    wget https://dist.nuget.org/win-x86-commandline/latest-prerelease/nuget.exe -OutFile $nugetExe
}

# Restoring tools required for build
if ($SkipRestore -eq $False)
{
    Trace-Log "Restoring tools"
    & $nugetExe restore .nuget\packages.config -SolutionDirectory .
}

## Validating DNVM installed and install it if missing
if ((Test-Path $dnvmLoc) -eq $False)
{
    Trace-Log "Downloading DNVM"
    &{$Branch='dev';iex ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/aspnet/Home/dev/dnvminstall.ps1'))}
}

## Clean artifacts and nupkgs folder
if (Test-Path $nupkgsDir)
{
    Trace-Log "Cleaning nupkgs folder"
    Remove-Item $nupkgsDir\*.nupkg
}

if( Test-Path $artifacts)
{
    Trace-Log "Cleaning the artifacts folder"
    Remove-Item $artifacts\*.* -Recurse
}

## Make sure the needed DNX runtimes ex
Trace-Log "Validating the correct DNX runtime set"
$env:DNX_FEED="https://www.nuget.org/api/v2"
& dnvm install 1.0.0-rc1-update1 -runtime CoreCLR -arch x86
& dnvm install 1.0.0-rc1-update1 -runtime CLR -arch x86 -alias default

if($CleanCache)
{
    CleanCache
}

# enable delay signed build
if ($DelaySign)
{
    if (Test-Path $MSPFXPath)
    {
        Trace-Log "Setting NuGet.Core solution to delay sign using $MSPFXPath"
        $env:DNX_BUILD_KEY_FILE=$MSPFXPath
        $env:DNX_BUILD_DELAY_SIGN=$true
    }

    if (Test-Path $NuGetPFXPath)
    {
        Trace-Log "Setting NuGet.Clients solution to delay sign using $NuGetPFXPath"
        $env:NUGET_PFX_PATH= $NuGetPFXPath

        Trace-Log "Using the Microsoft Key for NuGet Command line $MSPFXPath"
        $env:MS_PFX_PATH=$MSPFXPath
    }
}

$SemanticVersionDate = "2015-11-30"

if(!$BuildNumber)
{
    $R = ""
    $BuildNumber = ([Math]::DivRem(([System.DateTime]::Now.Subtract([System.DateTime]::Parse($SemanticVersionDate)).TotalMinutes), 5, [ref]$R)).ToString('F0')
}
else
{
    $buildNum = [int]$BuildNumber
    $BuildNumber = $buildNum.ToString("D4");
}

if(!$SkipXProj)
{
    ## Building all XProj projects
    BuildXproj
}

## Building the Tooling solution
if (-not $SkipCSproj)
{
    BuildCSproj
}

if ((-not $SkipILMerge) -and (-not $SkipCSProj))
{
    ## Merging the NuGet.exe
    ILMergeNuGet
}

## Calculating Build time
$endTime = [DateTime]::UtcNow
$diff = [math]::Round(($endTime - $startTime).TotalMinutes, 4)

Trace-Log
Trace-Log "Build ended at $endTime"
Trace-Log "Build took $diff minutes"
Trace-Log

popd