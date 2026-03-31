using namespace System.Security.Cryptography
[CmdletBinding()]
Param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$LuminaPackageVersion,

    [Parameter(Mandatory=$false)]
    [switch]$ReleaseLumina,

    [Parameter(Position=1, Mandatory=$false, ValueFromRemainingArguments=$true)]
    [string[]]$BuildArguments
)

Write-Output "PowerShell $($PSVersionTable.PSEdition) version $($PSVersionTable.PSVersion)"

Set-StrictMode -Version 2.0; $ErrorActionPreference = "Stop"; $ConfirmPreference = "None"; trap { Write-Error $_ -ErrorAction Continue; exit 1 }
$repoRoot = Split-Path $MyInvocation.MyCommand.Path -Parent

###########################################################################
# CONFIGURATION
###########################################################################

$luminaBuildScriptPath = Join-Path $repoRoot "lib\Lumina\src\build.ps1"
$luminaPackageOutputDir = Join-Path $repoRoot "lib\Lumina\src\Lumina\bin\Release"
$localNugetDir = Join-Path $repoRoot ".local-nuget"
$rootDirectoryPackagesPropsPath = Join-Path $repoRoot "Directory.Packages.props"
$luminaVersionMapPath = Join-Path $localNugetDir "lumina-version-map.json"
$TempDirectory = "$repoRoot\\.nuke\temp"

$DotNetGlobalFile = "$repoRoot\\global.json"
$DotNetInstallUrl = "https://dot.net/v1/dotnet-install.ps1"
$DotNetChannel = "Current"

$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 1
$env:DOTNET_CLI_TELEMETRY_OPTOUT = 1
$env:DOTNET_MULTILEVEL_LOOKUP = 0

###########################################################################
# EXECUTION
###########################################################################

function ExecSafe([scriptblock] $cmd) {
    & $cmd
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

function Get-FileSha256Hex([string] $value) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
    $hashBytes = [SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hashBytes)).ToLowerInvariant()
}

function Get-FileSha256HexFromPath([string] $path) {
    $stream = [System.IO.File]::OpenRead($path)
    try {
        $hashBytes = [SHA256]::HashData($stream)
    }
    finally {
        $stream.Dispose()
    }
    return ([Convert]::ToHexString($hashBytes)).ToLowerInvariant()
}

function Get-DirectorySnapshotHash([string] $rootPath) {
    $trackedAndUntrackedRaw = & git -C $rootPath ls-files --cached --others --exclude-standard
    if ($LASTEXITCODE) {
        throw "Failed to enumerate lib/Lumina tracked files."
    }

    $deletedRaw = & git -C $rootPath ls-files --deleted
    if ($LASTEXITCODE) {
        throw "Failed to enumerate lib/Lumina deleted files."
    }

    $trackedAndUntracked = @($trackedAndUntrackedRaw | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $deleted = @($deletedRaw | ForEach-Object { "$_".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in $trackedAndUntracked) {
        $fullPath = Join-Path $rootPath $relativePath
        if (-not (Test-Path $fullPath -PathType Leaf)) {
            continue
        }

        $contentHash = Get-FileSha256HexFromPath $fullPath
        $entries.Add("F $relativePath $contentHash")
    }

    foreach ($relativePath in $deleted) {
        $entries.Add("D $relativePath")
    }

    if ($entries.Count -eq 0) {
        return "empty"
    }

    return Get-FileSha256Hex (($entries | Sort-Object) -join "`n")
}

function Get-LuminaVersionMap {
    if (-not (Test-Path $luminaVersionMapPath)) {
        return @{}
    }

    $raw = Get-Content -Path $luminaVersionMapPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $map = @{}
    $json = $raw | ConvertFrom-Json
    foreach ($property in $json.PSObject.Properties) {
        $entry = $property.Value
        $map[$property.Name] = @{
            Version = [string]$entry.Version
            PackageSha256 = [string]$entry.PackageSha256
        }
    }

    return $map
}

function Save-LuminaVersionMap([hashtable] $map) {
    $json = $map | ConvertTo-Json
    Set-Content -Path $luminaVersionMapPath -Value $json -Encoding UTF8
}

function Get-ReusableLocalLuminaPackage([string] $luminaVersionKey, [hashtable] $versionMap) {
    if (-not $versionMap.ContainsKey($luminaVersionKey)) {
        return $null
    }

    $entry = $versionMap[$luminaVersionKey]
    if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.Version) -or [string]::IsNullOrWhiteSpace($entry.PackageSha256)) {
        return $null
    }

    $packagePath = Join-Path $localNugetDir "Lumina.$($entry.Version).nupkg"
    if (-not (Test-Path $packagePath)) {
        return $null
    }

    $actualHash = Get-FileSha256HexFromPath $packagePath
    if ($actualHash -ne $entry.PackageSha256) {
        return $null
    }

    return [pscustomobject]@{
        Version = $entry.Version
        PackagePath = $packagePath
        PackageSha256 = $actualHash
    }
}

function Get-LuminaVersionKey {
    $luminaRoot = Join-Path $repoRoot "lib\Lumina"
    $headRaw = & git -C $luminaRoot rev-parse HEAD
    if ($LASTEXITCODE) {
        throw "Failed to resolve lib/Lumina HEAD commit."
    }
    $head = if ($null -eq $headRaw) { "" } else { [string]$headRaw }
    $head = $head.Trim()

    $snapshotHash = Get-DirectorySnapshotHash $luminaRoot
    return "$head|$snapshotHash"
}

function Get-EffectiveLuminaPackageVersion {
    if ($ReleaseLumina) {
        return [pscustomobject]@{
            VersionKey = $null
            Version = $LuminaPackageVersion
            ReusablePackage = $null
            VersionMap = @{}
        }
    }

    $versionKey = Get-LuminaVersionKey
    $versionMap = Get-LuminaVersionMap
    $reusablePackage = Get-ReusableLocalLuminaPackage -luminaVersionKey $versionKey -versionMap $versionMap

    if ($null -ne $reusablePackage) {
        return [pscustomobject]@{
            VersionKey = $versionKey
            Version = $reusablePackage.Version
            ReusablePackage = $reusablePackage
            VersionMap = $versionMap
        }
    }

    $timestampSuffix = Get-Date -Format "yyyyMMdd.HHmmss"
    return [pscustomobject]@{
        VersionKey = $versionKey
        Version = "$LuminaPackageVersion.dev.$timestampSuffix"
        ReusablePackage = $null
        VersionMap = $versionMap
    }
}

function Get-LocalLuminaPackage([string] $luminaPackageVersion) {
    $package = Get-ChildItem -Path $luminaPackageOutputDir -Filter "Lumina.$luminaPackageVersion.nupkg" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*.symbols.nupkg" -and $_.Name -notlike "*.snupkg" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $package) {
        throw "No Lumina package for version '$luminaPackageVersion' was found under '$luminaPackageOutputDir'."
    }

    return $package
}

function Set-RootLuminaPackageVersion([string] $luminaPackageVersion) {
    $content = Get-Content -Path $rootDirectoryPackagesPropsPath -Raw
    $updatedContent = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        '<PackageVersion Include="Lumina" Version=".*?" />',
        "<PackageVersion Include=`"Lumina`" Version=`"$luminaPackageVersion`" />")

    if ($updatedContent -eq $content) {
        return
    }

    Set-Content -Path $rootDirectoryPackagesPropsPath -Value $updatedContent -Encoding UTF8
}

# If dotnet CLI is installed globally and it matches requested version, use for execution
if ($null -ne (Get-Command "dotnet" -ErrorAction SilentlyContinue) -and `
     $(dotnet --version) -and $LASTEXITCODE -eq 0) {
    $env:DOTNET_EXE = (Get-Command "dotnet").Path
}
else {
    # Download install script
    $DotNetInstallFile = "$TempDirectory\dotnet-install.ps1"
    New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($DotNetInstallUrl, $DotNetInstallFile)

    # If global.json exists, load expected version
    if (Test-Path $DotNetGlobalFile) {
        $DotNetGlobal = $(Get-Content $DotNetGlobalFile | Out-String | ConvertFrom-Json)
        if ($DotNetGlobal.PSObject.Properties["sdk"] -and $DotNetGlobal.sdk.PSObject.Properties["version"]) {
            $DotNetVersion = $DotNetGlobal.sdk.version
        }
    }

    # Install by channel or version
    $DotNetDirectory = "$TempDirectory\dotnet-win"
    if (!(Test-Path variable:DotNetVersion)) {
        ExecSafe { & $DotNetInstallFile -InstallDir $DotNetDirectory -Channel $DotNetChannel -NoPath }
    } else {
        ExecSafe { & $DotNetInstallFile -InstallDir $DotNetDirectory -Version $DotNetVersion -NoPath }
    }
    $env:DOTNET_EXE = "$DotNetDirectory\dotnet.exe"
}

Write-Output "Microsoft (R) .NET Core SDK version $(& $env:DOTNET_EXE --version)"

New-Item -ItemType Directory -Path $localNugetDir -Force | Out-Null
$luminaVersionResolution = Get-EffectiveLuminaPackageVersion
$effectiveLuminaPackageVersion = $luminaVersionResolution.Version

Write-Host "Local NuGet feed: $localNugetDir"
Write-Host "Resolved Lumina package version: $effectiveLuminaPackageVersion"

if ($null -ne $luminaVersionResolution.ReusablePackage) {
    Write-Host "Reusing local Lumina package: $($luminaVersionResolution.ReusablePackage.PackagePath)"
} else {
    Write-Host "Building `lib/Lumina` (submodule)..."
    ExecSafe { & $luminaBuildScriptPath -PackageVersion $effectiveLuminaPackageVersion -Configuration Release }

    $luminaPackage = Get-LocalLuminaPackage -luminaPackageVersion $effectiveLuminaPackageVersion
    Write-Host "Pushing local Lumina package: $($luminaPackage.FullName)"
    ExecSafe { & $env:DOTNET_EXE nuget push $luminaPackage.FullName --source $localNugetDir }

    if (-not $ReleaseLumina) {
        $luminaVersionResolution.VersionMap[$luminaVersionResolution.VersionKey] = @{
            Version = $effectiveLuminaPackageVersion
            PackageSha256 = (Get-FileSha256HexFromPath $luminaPackage.FullName)
        }
        Save-LuminaVersionMap $luminaVersionResolution.VersionMap
    }
}

Write-Host "Using local Lumina package version for solution: $effectiveLuminaPackageVersion"
Set-RootLuminaPackageVersion -luminaPackageVersion $effectiveLuminaPackageVersion

# --configuration [Debug|Release], default: Debug
ExecSafe { & (Join-Path $repoRoot "build.ps1") @BuildArguments }
