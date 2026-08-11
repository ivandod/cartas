param(
    [ValidatePattern('^\d+$')]
    [string]$ProjectId = "1648457",
    [string]$Tag = $env:GITHUB_REF_NAME,
    [string]$ZipPath,
    [string]$Changelog,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ZipPath) {
    $ZipPath = Join-Path $projectRoot "Wow-Midnight-Cartas-Last-Version.zip"
}

$tocPath = Join-Path $projectRoot "Cartas.toc"
$versionMatch = Select-String -LiteralPath $tocPath -Pattern '^## Version:\s*(.+)$' | Select-Object -First 1
$interfaceMatch = Select-String -LiteralPath $tocPath -Pattern '^## Interface:\s*(\d+)' | Select-Object -First 1
if (-not $versionMatch) { throw "Cartas.toc does not contain ## Version." }
if (-not $interfaceMatch) { throw "Cartas.toc does not contain a numeric ## Interface." }

$version = $versionMatch.Matches[0].Groups[1].Value.Trim()
if ([string]::IsNullOrWhiteSpace($Tag)) { throw "A release tag is required." }
$tagVersion = $Tag -replace '^v', ''
if ($tagVersion -cne $version) {
    throw "Tag $Tag does not match Cartas.toc version $version."
}

$releaseType = if ($Tag -match '(?i)alpha') {
    "alpha"
}
elseif ($Tag -match '(?i)(beta|rc)') {
    "beta"
}
else {
    "release"
}

$interface = [int]$interfaceMatch.Matches[0].Groups[1].Value
$major = [math]::Floor($interface / 10000)
$minor = [math]::Floor(($interface % 10000) / 100)
$patch = $interface % 100
$gameVersion = "$major.$minor.$patch"

$resolvedZip = (Resolve-Path -LiteralPath $ZipPath).Path
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($resolvedZip)
try {
    $actualEntries = @($archive.Entries | ForEach-Object FullName | Sort-Object)
}
finally {
    $archive.Dispose()
}
$expectedEntries = @(
    "Cartas/Cartas.lua"
    "Cartas/Cartas.toc"
    "Cartas/README.txt"
) | Sort-Object
if (($actualEntries -join "`n") -cne ($expectedEntries -join "`n")) {
    throw "The CurseForge ZIP contains unexpected files: $($actualEntries -join ', ')"
}

if ([string]::IsNullOrWhiteSpace($Changelog)) {
    $tagExists = @(& git -C $projectRoot tag --list $Tag) -contains $Tag

    if ($tagExists) {
        $reachableTags = @(& git -C $projectRoot tag --merged $Tag --sort=-creatordate)
        $previousTag = $reachableTags | Where-Object { $_ -ne $Tag } | Select-Object -First 1
        $range = if ($previousTag) { "$previousTag..$Tag" } else { $Tag }
        $lines = @(& git -C $projectRoot log --max-count=100 --pretty=format:'- %s (%h)' $range)
        if ($LASTEXITCODE -eq 0 -and $lines.Count -gt 0) {
            $Changelog = $lines -join "`n"
        }
    }
    if ([string]::IsNullOrWhiteSpace($Changelog)) {
        $Changelog = "Cartas $version"
    }
}

$metadata = [ordered]@{
    changelog = $Changelog
    changelogType = "markdown"
    displayName = "Cartas $version"
    gameVersionNames = @($gameVersion)
    releaseType = $releaseType
    isMarkedForManualRelease = $false
} | ConvertTo-Json -Compress -Depth 5

$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedZip).Hash
if ($DryRun) {
    return [pscustomobject]@{
        ProjectId = $ProjectId
        Tag = $Tag
        Version = $version
        ReleaseType = $releaseType
        GameVersion = $gameVersion
        ZipSHA256 = $zipHash
        Entries = $actualEntries.Count
        Uploaded = $false
    }
}

if ([string]::IsNullOrWhiteSpace($env:CF_API_KEY)) {
    throw "CF_API_KEY is required to publish to CurseForge."
}

$endpoint = "https://wow.curseforge.com/api/projects/$ProjectId/upload-file"
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$form = New-Object System.Net.Http.MultipartFormDataContent
$fileStream = $null
$fileContent = $null
$metadataContent = $null
$httpResponse = $null
try {
    $client.DefaultRequestHeaders.Add("X-Api-Token", $env:CF_API_KEY)
    $metadataContent = New-Object System.Net.Http.StringContent($metadata, [Text.Encoding]::UTF8, "application/json")
    $form.Add($metadataContent, "metadata")

    $fileStream = [IO.File]::OpenRead($resolvedZip)
    $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
    $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/zip")
    $form.Add($fileContent, "file", [IO.Path]::GetFileName($resolvedZip))

    $httpResponse = $client.PostAsync($endpoint, $form).GetAwaiter().GetResult()
    $response = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $httpResponse.IsSuccessStatusCode) {
        throw "CurseForge upload failed with HTTP $([int]$httpResponse.StatusCode): $response"
    }
}
finally {
    if ($httpResponse) { $httpResponse.Dispose() }
    if ($fileContent) { $fileContent.Dispose() }
    elseif ($fileStream) { $fileStream.Dispose() }
    if ($metadataContent) { $metadataContent.Dispose() }
    $form.Dispose()
    $client.Dispose()
}
$result = $response | ConvertFrom-Json
if (-not $result.id) {
    throw "CurseForge did not return a file ID: $response"
}

[pscustomobject]@{
    ProjectId = $ProjectId
    FileId = $result.id
    Tag = $Tag
    Version = $version
    ReleaseType = $releaseType
    GameVersion = $gameVersion
    ZipSHA256 = $zipHash
    Uploaded = $true
}
