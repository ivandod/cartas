param(
    [string]$SavedVariables
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$luaCommand = Get-Command lua -ErrorAction SilentlyContinue
$fallbackRoot = ${env:ProgramFiles(x86)}
$fallbackLua = if ($fallbackRoot) { Join-Path $fallbackRoot "Lua\5.1\lua.exe" } else { $null }
$lua = if ($luaCommand) { $luaCommand.Source } else { $fallbackLua }

if (-not $lua -or -not (Test-Path -LiteralPath $lua)) {
    throw "Lua 5.1 not found. Install it with: winget install --id rjpcomputing.luaforwindows --exact"
}

Push-Location $repo
try {
    & $lua "tests/test_cartas.lua"
    if ($LASTEXITCODE -ne 0) { throw "Unit tests failed with exit code $LASTEXITCODE" }

    if ($SavedVariables) {
        $resolved = (Resolve-Path -LiteralPath $SavedVariables).Path
        & $lua "tests/validate_saved_variables.lua" $resolved
        if ($LASTEXITCODE -ne 0) { throw "SavedVariables validation failed with exit code $LASTEXITCODE" }
    }
}
finally {
    Pop-Location
}
