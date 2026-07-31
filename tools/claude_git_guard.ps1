<#
.SYNOPSIS
    Claude Code PreToolUse guard for Bash: denies dangerous git operations
    before they run, inside a Claude session.

.DESCRIPTION
    Second line of defense alongside .githooks/pre-commit and .githooks/pre-push
    (see CLAUDE.md for the invariant being protected: bots own live-trading
    state paths, human/Claude own code, main only advances via PR). This is a
    fast heuristic pre-filter on the command text — the git hooks underneath
    are the authoritative backstop that inspect actual git state.

    Invoked by Claude Code as a PreToolUse hook matched on the Bash tool. Reads
    the tool-call JSON from stdin ({tool_name, tool_input: {command, ...}, ...}).
    Exit 2 + stderr message = deny the tool call. Exit 0 = allow.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Deny([string]$msg) {
    [Console]::Error.WriteLine("BLOCKED by claude_git_guard: $msg")
    exit 2
}

try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json
} catch {
    # Can't parse input — fail open, don't block unrelated tool calls.
    exit 0
}

if ($payload.tool_name -ne 'Bash') { exit 0 }
$command = $payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

# Identity gate: no-op for bot identities, mirroring .githooks/*. Checks both
# ambient git config and an inline '-c user.name=...' override (how the VPS
# tick scripts actually invoke git: git -c user.name='live-desk-bot' commit).
$botNames = @('live-desk-bot', 'paper-desk-bot')
if ($command -match "-c\s+user\.name=['""]?(live-desk-bot|paper-desk-bot)['""]?") { exit 0 }
try {
    $ambientName = (git config user.name 2>$null)
} catch { $ambientName = $null }
if ($ambientName -and ($botNames -contains $ambientName)) { exit 0 }

# Cheap bail-out: most Bash calls have nothing to do with git.
if ($command -notmatch '\bgit\b') { exit 0 }

$normalized = $command -replace '\\', '/'

# ---------------------------------------------------------------------------
# 1) Force-push (any spelling): --force, --force-with-lease, bare -f, or a
#    '+refspec' push.
# ---------------------------------------------------------------------------
$isPush = $normalized -match '\bgit\s+push\b'
if ($isPush) {
    $isForce = ($normalized -match '--force(-with-lease)?\b') `
        -or ($normalized -match '(^|\s)-f(\s|$)') `
        -or ($normalized -match '\bpush\b[^|&;]*\s\+[^\s:]+:')
    if ($isForce) {
        Deny "force-push detected ('$command'). This risks rewriting bot-authored history on origin/main. See CLAUDE.md."
    }

    # 2) Direct push to main — integration must go through a PR.
    if ($normalized -match '(?:\s|:)main(?:\s|$)') {
        Deny "direct push to 'main' detected ('$command'). Push your branch and open a PR instead. See CLAUDE.md."
    }
}

# ---------------------------------------------------------------------------
# 3) Destructive git commands (reset --hard / checkout -- . / clean -f) while
#    on branch main.
# ---------------------------------------------------------------------------
$isDestructive = ($normalized -match '\bgit\s+reset\s+--hard\b') `
    -or ($normalized -match '\bgit\s+checkout\s+--\s+\.') `
    -or ($normalized -match '\bgit\s+clean\s+-[a-zA-Z]*f')
if ($isDestructive) {
    try {
        $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
    } catch { $branch = $null }
    if ($branch -eq 'main') {
        Deny "destructive git command on branch 'main' ('$command'). See CLAUDE.md protocol."
    }
}

# ---------------------------------------------------------------------------
# 4) Staging bot-owned live state: explicit 'git add <path>' on a protected
#    path, or 'git commit -a/-am/--all' while the working tree has protected
#    paths modified.
# ---------------------------------------------------------------------------
$protectedRe = '^(data/live_real/|data/live_rf/|journal_live\.md$|journal_live_rf\.md$|data/rf/manual_close_req\.json$)'
$exemptRe = '^data/live_rf/(config\.json$|candles/)'

function Test-ProtectedPath([string]$p) {
    $p = $p.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    if ($p -match $exemptRe) { return $false }
    return ($p -match $protectedRe)
}

if ($normalized -match '\bgit\s+add\s+([^|&;]+)') {
    $argsPart = $Matches[1]
    $tokens = $argsPart -split '\s+' | Where-Object { $_ -and ($_ -notmatch '^-') }
    foreach ($t in $tokens) {
        if (Test-ProtectedPath $t) {
            Deny "'git add' targets bot-owned live state path '$t'. See CLAUDE.md ownership table."
        }
    }
}

if ($normalized -match '\bgit\s+commit\b[^|&;]*\s(-a\b|-am\b|--all\b)') {
    try {
        $status = git status --porcelain 2>$null
    } catch { $status = $null }
    if ($status) {
        foreach ($line in $status) {
            if ($line.Length -lt 4) { continue }
            $xy = $line.Substring(0, 2)
            if ($xy -match '\?\?') { continue }  # untracked, -a won't stage it
            $path = $line.Substring(3) -replace '\\', '/'
            if (Test-ProtectedPath $path) {
                Deny "'git commit -a' would stage bot-owned live state path '$path'. See CLAUDE.md ownership table."
            }
        }
    }
}

exit 0
