### Constants ###
$NuGetClientRoot = Split-Path -Path $PSScriptRoot -Parent
$msbuildExe = "${env:ProgramFiles(x86)}\MSBuild\14.0\Bin\msbuild.exe"
$nugetExe = ".nuget\nuget.exe"
$ILMerge = Join-Path $NuGetClientRoot "packages\ILMerge.2.14.1208\tools\ILMerge.exe"
$dnvmLoc = Join-Path $env:USERPROFILE ".dnx\bin\dnvm.cmd"
$nupkgsDir = Join-Path $NuGetClientRoot "nupkgs"
$artifacts = Join-Path $NuGetClientRoot "artifacts"

### Functions ###
Function Trace-Log($TraceMessage = '') {
    Write-Host "[$(Trace-Time)]`t$TraceMessage" -ForegroundColor Cyan
}

Function Error-Log($ErrorMessage) {
    Write-Error "[$(Trace-Time)]`t[ERROR] $ErrorMessage"
}

Function Trace-Time() {
    $prev = $Global:LastTraceTime;
    $currentTime = Get-Date;
    $time = $currentTime.ToString("HH:mm:ss");
    $diff = New-TimeSpan -Start $prev -End $currentTime
    $Global:LastTraceTime = $currentTime;
    "$time +$([math]::Round($diff.TotalSeconds, 0))"
}

$Global:LastTraceTime = Get-Date

Function Update-Submodules {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -Path "$NuGetClientRoot/submodules/FileSystem/src"))
    {
        Trace-Log "Updating and initializing submodules"
        & git submodule update --init 2>&1
    }
    else
    {
        Trace-Log "Updating submodules"
        & git submodule update 2>&1
    }
}

# Downloads NuGet.exe if missing
Function Install-NuGet() {
    if (-not (Test-Path $nugetExe))
    {
        Trace-Log "Downloading nuget.exe"
        wget https://dist.nuget.org/win-x86-commandline/latest-prerelease/nuget.exe -OutFile $nugetExe
    }
}

# Validates DNVM installed and installs it if missing
Function Install-DNVM() {
    if (-not (Test-Path $dnvmLoc))
    {
        Trace-Log "Downloading DNVM"
        &{$Branch='dev';iex ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/aspnet/Home/dev/dnvminstall.ps1'))}
    }
}

# Makes sure the needed DNX runtimes installed
Function Install-DNX() {
    Trace-Log "Validating the correct DNX runtime set"
    $env:DNX_FEED="https://www.nuget.org/api/v2"
    & dnvm install 1.0.0-rc1-update1 -runtime CoreCLR -arch x86 2>&1
    & dnvm install 1.0.0-rc1-update1 -runtime CLR -arch x86 -alias default 2>&1
}

# Enables delay signed build
Function Enable-DelayedSigning() {
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

Function Get-BuildNumber {
    param([string]$BuildNumber)
    $SemanticVersionDate = '2015-11-30'
    if(!$BuildNumber) {
        $R = ""
        '{0:F0}' -f ([Math]::DivRem(([System.DateTime]::Now.Subtract([System.DateTime]::Parse($SemanticVersionDate)).TotalMinutes), 5, [ref]$R))
    }
    else {
        '{0:D4}' -f ([int]$BuildNumber)
    }
}

## Cleans the machine level cache from all packages
Function Clear-PackageCache() {
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

## Cleans artifacts and nupkgs folder
Function Clear-Artifacts() {
    if (Test-Path $nupkgsDir)
    {
        Trace-Log "Cleaning nupkgs folder"
        Remove-Item $nupkgsDir\*.nupkg -Force
    }

    if( Test-Path $artifacts)
    {
        Trace-Log "Cleaning the artifacts folder"
        Remove-Item $artifacts\*.* -Recurse -Force
    }
}

Function Restore-SolutionPackages() {
    Trace-Log "Restoring solution packages"
    & $nugetExe restore "${NuGetClientRoot}\.nuget\packages.config" -SolutionDirectory $NuGetClientRoot 2>&1
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

Function Invoke-DnuPack()
{
    ## Setting the DNX build version
    if($ReleaseLabel -ne "Release")
    {
        $env:DNX_BUILD_VERSION="$ReleaseLabel-$BuildNumber"
    }

    # Setting the DNX AssemblyFileVersion
    $env:DNX_ASSEMBLY_FILE_VERSION=$BuildNumber

    $projectsLocation = src\NuGet.Core

    $xprojects = Get-ChildItem $projectsLocation -rec -Filter '*.xproj' |`
        %{ Split-Path $_.FullName -Parent } |`
        ?{ -not $_.EndsWith('NuGet.CommandLine.XPlat') } # TODO: Remove this after fixing XPLAT!

    if (-not $SkipRestore)
    {
        if ($Fast)
        {
            Restore-XProjFast $projectsLocation
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
    &dnu $opts 2>&1

    ## Moving nupkgs
    Trace-Log "Moving the packages to $nupkgsDir"
    Get-ChildItem $artifacts\*.nupkg -Recurse | % { Move-Item $_ $nupkgsDir }
}

Function Test-XProj() {
    # Test assemblies should not be signed
    if (Test-Path Env:\DNX_BUILD_KEY_FILE)
    {
        Remove-Item Env:\DNX_BUILD_KEY_FILE
    }

    if (Test-Path Env:\DNX_BUILD_DELAY_SIGN)
    {
        Remove-Item Env:\DNX_BUILD_DELAY_SIGN
    }

    $projectsLocation = test\NuGet.Core.Tests

    $xtests = Get-ChildItem $projectsLocation -rec -Filter '*.xproj' |`
        %{ Split-Path $_.FullName -Parent }

    if ($Fast)
    {
        Restore-XProjFast $projectsLocation
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
        & dnx test 2>&1
        popd
    }
}

Function Build-CSproj()
{
    #Building the microsoft interop package for the test.utility
    $interopLib = ".\lib\Microsoft.VisualStudio.ProjectSystem.Interop"
    & dnu restore $interopLib -s https://www.myget.org/F/nuget-volatile/api/v2/ -s https://www.nuget.org/api/v2/
    & dnu pack $interopLib
    Get-ChildItem $interopLib\*.nupkg -Recurse | % { Move-Item $_ $nupkgsDir }

    # Restore packages for NuGet.Tooling solution
    & $nugetExe restore -msbuildVersion 14 .\NuGet.Clients.sln

    # Build the solution
    & $msbuildExe .\NuGet.Clients.sln "/p:Configuration=$Configuration;ReleaseLabel=$ReleaseLabel;BuildNumber=$BuildNumber;RunTests=$RunTests" 2>&1

    Trace-Log "Copying the Vsix to $artifacts"
    $visxLocation = Join-Path $artifacts "$Configuration\NuGet.Clients\VsExtension"
    Copy-Item $visxLocation\NuGet.Tools.vsix $artifacts
}

# Merges the NuGet.exe
Function Invoke-ILMerge()
{
    $nugetArtifactsFolder = Join-Path $artifacts "$Configuration\NuGet.Clients\NuGet.CommandLine"
    pushd $nugetArtifactsFolder

    Trace-Log "Creating the ilmerged nuget.exe"
    & $ILMerge NuGet.exe NuGet.Client.dll NuGet.Commands.dll NuGet.Configuration.dll NuGet.ContentModel.dll NuGet.Core.dll NuGet.Credentials.dll NuGet.DependencyResolver.Core.dll NuGet.DependencyResolver.dll NuGet.Frameworks.dll NuGet.LibraryModel.dll NuGet.Logging.dll NuGet.PackageManagement.dll NuGet.Packaging.Core.dll NuGet.Packaging.Core.Types.dll NuGet.Packaging.dll NuGet.ProjectManagement.dll NuGet.ProjectModel.dll NuGet.Protocol.Core.Types.dll NuGet.Protocol.Core.v2.dll NuGet.Protocol.Core.v3.dll NuGet.Repositories.dll NuGet.Resolver.dll NuGet.RuntimeModel.dll NuGet.Versioning.dll Microsoft.Web.XmlTransform.dll Newtonsoft.Json.dll /log:mergelog.txt /out:$artifacts\NuGet.exe 2>&1

    popd
}

Function child() {
    Error-Log "fail!"
}

Function Fails-Always {
    [CmdletBinding()]
    param()
    process {
        child "fail!" -ea $ErrorActionPreference
        trace-log "success"
        }
}