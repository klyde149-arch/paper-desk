<#
.SYNOPSIS
    Activates this repo's local git guardrail hooks (.githooks/) on this machine.

.DESCRIPTION
    Sets core.hooksPath to .githooks for THIS clone only. core.hooksPath lives in
    .git/config, which is never committed and never reaches the VPS — the live
    trading contour is untouched by this script. See CLAUDE.md for what the
    hooks protect against and why.

    Safe to re-run.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    Write-Error "Not inside a git repository."
    exit 1
}

$hooksDir = Join-Path $repoRoot '.githooks'
if (-not (Test-Path $hooksDir)) {
    Write-Error "Expected hooks directory not found: $hooksDir"
    exit 1
}

git config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set core.hooksPath."
    exit 1
}

Write-Host "core.hooksPath set to .githooks (local to this clone only)." -ForegroundColor Green
Write-Host "Active hooks:" -ForegroundColor Green
Get-ChildItem $hooksDir -File | Where-Object { $_.Name -notmatch '\.(md|txt)$' } | ForEach-Object {
    Write-Host "  - $($_.Name)"
}
Write-Host "Verify: git config core.hooksPath"
