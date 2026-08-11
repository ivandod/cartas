param(
    [string]$OutputDirectory,
    [string]$Label,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot "Releases"
}

$tocPath = Join-Path $projectRoot "Cartas.toc"
$versionLine = Select-String -LiteralPath $tocPath -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1
if (-not $versionLine) { throw "Cartas.toc does not contain a version" }
$version = $versionLine.Matches[0].Groups[1].Value.Trim()

$suffix = ""
if ($Label) {
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if ($safeLabel) { $suffix = "-$safeLabel" }
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$zipPath = Join-Path $outputRoot "Cartas-WoW-Midnight-v$version$suffix.zip"
if ((Test-Path -LiteralPath $zipPath) -and -not $Force) {
    throw "Release already exists: $zipPath (use -Force to replace it)"
}

$runtimeFiles = @("Cartas.lua", "Cartas.toc", "README.txt")
foreach ($name in $runtimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $name))) {
        throw "Missing runtime file: $name"
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $runtimeFiles) {
        $source = Join-Path $projectRoot $name
        $entryName = "Cartas/$name"
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $source,
            $entryName,
            [IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

$check = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $actual = @($check.Entries | ForEach-Object FullName | Sort-Object)
    $expected = @($runtimeFiles | ForEach-Object { "Cartas/$_" } | Sort-Object)
    if (($actual -join "`n") -ne ($expected -join "`n")) {
        throw "Unexpected ZIP content: $($actual -join ', ')"
    }
}
finally {
    $check.Dispose()
}

$publicZipPath = Join-Path $projectRoot "Wow-Midnight-Cartas-Last-Version.zip"
Copy-Item -LiteralPath $zipPath -Destination $publicZipPath -Force

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath
[pscustomobject]@{
    Version = $version
    Zip = $zipPath
    PublicZip = $publicZipPath
    SHA256 = $hash.Hash
}
