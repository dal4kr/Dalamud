[CmdletBinding()]
Param()

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ConfirmPreference = "None"
trap {
    Write-Error $_ -ErrorAction Continue
    exit 1
}

$repoRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
$releaseDir = Join-Path $repoRoot "bin\Release"
$hashScriptPath = Join-Path $repoRoot "CreateHashList.ps1"
$packDir = Join-Path $repoRoot "pack"
$zipPath = Join-Path $packDir "Release.zip"
$releaseHashPath = Join-Path $packDir "hashes.json.hash"
$cachedSigsDir = Join-Path $releaseDir "cachedSigs"

if (-not (Test-Path $releaseDir)) {
    throw "Release directory not found: $releaseDir"
}

if (-not (Test-Path $hashScriptPath)) {
    throw "Hash list script not found: $hashScriptPath"
}

Write-Host "Generating hashes for $releaseDir"
Push-Location
try {
    $hashScriptOutput = & $hashScriptPath $releaseDir
}
finally {
    Pop-Location
}

$hashFileHash = $null
if ($hashScriptOutput) {
    $hashFileHash = ($hashScriptOutput | Select-Object -Last 1).Hash
}

if (-not (Test-Path $packDir)) {
    New-Item -ItemType Directory -Path $packDir -Force | Out-Null
}

if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

function Add-DirectoryToZip {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory=$true)]
        [string]$DestinationZipPath
    )

    $sourceRoot = (Resolve-Path $SourceDirectory).Path
    $zipArchive = [System.IO.Compression.ZipFile]::Open($DestinationZipPath, [System.IO.Compression.ZipArchiveMode]::Create)

    try {
        $filesToPack = Get-ChildItem -Path $sourceRoot -Recurse -File | Where-Object {
            $_.Extension -ne ".log" -and $_.FullName -notlike "$cachedSigsDir*"
        }

        foreach ($file in $filesToPack) {
            $entryName = $file.FullName.Substring($sourceRoot.Length).TrimStart('\') -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        $zipArchive.Dispose()
    }
}

Write-Host "Creating archive: $zipPath"
Add-DirectoryToZip -SourceDirectory $releaseDir -DestinationZipPath $zipPath

if (-not [string]::IsNullOrWhiteSpace($hashFileHash)) {
    Set-Content -Path $releaseHashPath -Value $hashFileHash -Encoding ASCII
    Write-Host "hashes.json MD5: $hashFileHash"
    Write-Host "Saved hash to: $releaseHashPath"
}
