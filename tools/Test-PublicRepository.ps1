$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$publicZipName = "Wow-Midnight-Cartas-Last-Version.zip"
$runtimeFiles = @("Cartas.lua", "Cartas.toc", "README.txt")

Push-Location $projectRoot
try {
    $tracked = @(git ls-files)
    if ($LASTEXITCODE -ne 0) { throw "Unable to list tracked files" }

    $forbiddenPathPatterns = @(
        '(^|/)Releases/',
        '(^|/)Backups/',
        '(^|/)WTF/',
        '(^|/)SavedVariables/',
        '(^|/)\.codex/'
    )

    foreach ($path in $tracked) {
        foreach ($pattern in $forbiddenPathPatterns) {
            if ($path -match $pattern) { throw "Forbidden tracked path: $path" }
        }
        if ($path -match '\.zip$' -and $path -ne $publicZipName) {
            throw "Only $publicZipName may be tracked: $path"
        }
    }

    if ($tracked -notcontains $publicZipName) {
        throw "$publicZipName must be tracked"
    }

    $textExtensions = @('.lua', '.toc', '.txt', '.md', '.ps1', '.yml', '.yaml', '.gitignore', '.gitattributes')
    foreach ($path in $tracked) {
        $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($textExtensions -notcontains $extension -and $path -notin @('.gitignore', '.gitattributes')) {
            continue
        }

        $text = [IO.File]::ReadAllText((Join-Path $projectRoot $path))
        if ($text -match '(?<![A-Za-z])[A-Za-z]:[\\/]') {
            throw "Absolute Windows path found in tracked file: $path"
        }
        if ($text -match '(?i)Users[\\/][^<>\\/\s]+') {
            throw "User profile path found in tracked file: $path"
        }
        if ($text -match '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b') {
            throw "Potential UUID token found in tracked file: $path"
        }

        foreach ($match in [regex]::Matches($text, '(?i)WTF[\\/]Account[\\/]([^\\/\s`"'']+)')) {
            if ($match.Groups[1].Value -ne '<cuenta>') {
                throw "Concrete WoW account path found in tracked file: $path"
            }
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $projectRoot $publicZipName
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $actualEntries = @($archive.Entries | ForEach-Object FullName | Sort-Object)
        $expectedEntries = @($runtimeFiles | ForEach-Object { "Cartas/$_" } | Sort-Object)
        if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
            throw "Unexpected public ZIP content: $($actualEntries -join ', ')"
        }

        foreach ($name in $runtimeFiles) {
            $entry = $archive.GetEntry("Cartas/$name")
            $stream = $entry.Open()
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    $entryHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
                }
                finally {
                    $sha.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }

            $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $name)).Hash
            if ($entryHash -ne $sourceHash) {
                throw "Public ZIP entry does not match source: Cartas/$name"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    Write-Output "Public repository audit passed: $($tracked.Count) tracked files, one sanitized runtime ZIP."
}
finally {
    Pop-Location
}
