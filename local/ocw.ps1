#Requires -Version 5.1
<#
.SYNOPSIS
Local half of ocw: drive OpenCode workers running in a GitHub Codespace.

.DESCRIPTION
The Codespaces half (`ocw`, in the remote/ directory) owns worker lifecycle but
only runs inside the Codespace. This script is the computer half. It proxies
every verb over `gh codespace ssh` so you never hand-write a remote command, and
it adds one verb the remote half cannot have: `setup`, which installs the remote
payload into a Codespace.

Verbs:
  setup       install the remote payload into the Codespace
  start       launch a worker
  status      show one worker, or all of them
  logs        print the tail of a worker's raw log
  attach      follow a running worker's log, rendered as concise lines
  wait        block until a worker stops or a deadline passes
  stop        ask a running worker to terminate
  prune       delete state for workers that are no longer running
  bootstrap   install OpenCode when missing, or upgrade it when present
  dashboard   table of worker state across Codespaces, with a local cache
  codespaces  list available Codespaces
  version     print the remote ocw version

.EXAMPLE
  ./ocw.ps1 codespaces
.EXAMPLE
  ./ocw.ps1 -Codespace my-codespace setup
.EXAMPLE
  ./ocw.ps1 start lane-a opencode-go/deepseek-v4.1-flash high /workspaces/worktrees/lane-a lane-a ./prompt-lane-a.md
.EXAMPLE
  ./ocw.ps1 -Codespace my-codespace attach lane-a
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Verb = 'status',

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Rest,

    # Codespace to target. Falls back to $env:OCW_CODESPACE, then to the only
    # Codespace in the account when exactly one exists.
    [string]$Codespace,

    # Install location of the remote payload inside the Codespace.
    [string]$RemoteRoot,

    # status: request machine-readable JSON instead of a table.
    [switch]$Json,

    # dashboard: refresh continuously instead of rendering once.
    [switch]$Watch
)

$ErrorActionPreference = 'Stop'

$LocalRoot = $PSScriptRoot
$PackageRoot = Split-Path -Parent $LocalRoot
$RemoteRoot = if ($RemoteRoot) { $RemoteRoot }
              elseif ($env:OCW_REMOTE_ROOT) { $env:OCW_REMOTE_ROOT }
              else { '/home/codespace/remote-package' }
$CacheRoot = Join-Path $LocalRoot '.cache'
$Rest = @($Rest)

function Get-CodespaceList {
    <# List Codespaces once, so Codespace resolution and the dashboard agree. #>
    $names = & gh codespace list --json name --jq '.[].name' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'gh codespace list failed. Run: gh auth login'
    }
    return @($names | Where-Object { $_ })
}

function Resolve-Codespace {
    <# Resolve the target Codespace from parameter, environment, or the account. #>
    if ($Codespace) { return $Codespace }
    if ($env:OCW_CODESPACE) { return $env:OCW_CODESPACE }

    $available = Get-CodespaceList
    if ($available.Count -eq 1) { return $available[0] }
    if ($available.Count -eq 0) {
        throw 'No Codespaces found. Create one, or set OCW_CODESPACE.'
    }
    throw ("Several Codespaces exist, so none was assumed. " +
           "Pass -Codespace, or set OCW_CODESPACE. Available: " +
           ($available -join ', '))
}

function Quote-RemoteArg {
    <#
    Quote one argument for the remote shell. Prompts are frequently literal text
    with spaces, so every argument is quoted unless it is provably safe.
    #>
    param([string]$Value)
    if ($Value -match '^[A-Za-z0-9._/@=:+,^-]+$') { return $Value }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-Remote {
    <# Run `ocw VERB ARGS...` inside the Codespace and stream its output back. #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $command = "$RemoteRoot/ocw " +
               (($Arguments | ForEach-Object { Quote-RemoteArg $_ }) -join ' ')
    & gh codespace ssh -c $Target -- $command
    return $LASTEXITCODE
}

function Invoke-Setup {
    <#
    Install the remote payload into the Codespace.

    The payload is sent as base64 over stdin rather than assembled into the
    command string, so binary-safe transfer does not depend on shell quoting.
    #>
    param([Parameter(Mandatory)][string]$Target)

    $remote = Join-Path $PackageRoot 'remote'
    if (-not (Test-Path -LiteralPath $remote)) {
        throw "Remote payload not found at $remote"
    }

    $tarPath = Join-Path ([IO.Path]::GetTempPath()) ("ocw-remote-{0}.tar.gz" -f $PID)
    try {
        & tar -czf $tarPath -C $remote .
        if ($LASTEXITCODE -ne 0) { throw 'tar failed while packaging the remote payload.' }

        $encoded = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tarPath))
        $command = "mkdir -p $RemoteRoot && base64 -d | tar -xzf - -C $RemoteRoot && " +
                   "chmod +x $RemoteRoot/ocw $RemoteRoot/setup-worktrees.sh"
        $encoded | & gh codespace ssh -c $Target -- $command
        if ($LASTEXITCODE -ne 0) { throw 'Remote install failed.' }

        Write-Host "ocw installed into $Target at $RemoteRoot"
        Invoke-Remote -Target $Target -Arguments @('version') | Out-Null

        # A fresh Codespace has no OpenCode, so first-run setup also installs or
        # upgrades it. Without this the first `start` fails on a missing binary.
        Write-Host 'Preparing OpenCode...'
        $code = Invoke-Remote -Target $Target -Arguments @('bootstrap')
        if ($code -ne 0) { throw 'OpenCode bootstrap failed.' }
    }
    finally {
        Remove-Item -LiteralPath $tarPath -ErrorAction SilentlyContinue
    }
}

function Get-Snapshot {
    <#
    Read worker state from one Codespace as objects.

    A transient SSH failure must not read as "worker stopped", so the last good
    snapshot is cached and reused with its age attached.
    #>
    param([Parameter(Mandatory)][string]$Target, [int]$Retries = 3)

    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    $cachePath = Join-Path $CacheRoot ($Target + '.json')
    $lastError = ''

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $output = & gh codespace ssh -c $Target -- "python3 $RemoteRoot/worker-snapshot.py" 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $records = @($output | ConvertFrom-Json)
                $cache = [pscustomobject]@{
                    observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    records    = $records
                }
                [IO.File]::WriteAllText(
                    $cachePath,
                    ($cache | ConvertTo-Json -Depth 8 -Compress),
                    [Text.UTF8Encoding]::new($false)
                )
                foreach ($record in $records) { $record | Add-Member Observed 'LIVE' -Force }
                return $records
            }
            catch {
                $lastError = 'Invalid monitor JSON: ' + $_.Exception.Message
                break
            }
        }

        $lastError = (($output | Out-String).Trim() -replace '\s+', ' ')
        if ($attempt -lt $Retries) { Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1)) }
    }

    if (Test-Path -LiteralPath $cachePath) {
        try {
            $cache = Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$cache.observedAt
            $records = @($cache.records)
            foreach ($record in $records) {
                $record | Add-Member Observed ("CACHED {0}s" -f $age) -Force
            }
            return $records
        }
        catch {
            $lastError = $lastError + '; cache unreadable: ' + $_.Exception.Message
        }
    }

    return @([pscustomobject]@{
        name     = '<monitor>'
        state    = 'MONITOR_DOWN'
        model    = '-'
        variant  = '-'
        activity = $lastError
        message  = ''
        Observed = 'NONE'
    })
}

function Show-Dashboard {
    <# Render one compact table across every Codespace, or just the target one. #>
    $targets = if ($Codespace) { @($Codespace) } else { Get-CodespaceList }
    $rows = foreach ($target in $targets) {
        foreach ($record in (Get-Snapshot -Target $target)) {
            [pscustomobject]@{
                Codespace = $target
                Worker    = $record.name
                State     = $record.state
                Model     = (($record.model -replace '^opencode-go/', '') + '/' + $record.variant)
                Idle      = if ($null -eq $record.activityAgeSeconds) { '-' }
                            else { '{0}s' -f $record.activityAgeSeconds }
                Observed  = $record.Observed
                Activity  = $record.activity
            }
        }
    }
    $rows | Sort-Object Codespace, Worker |
        Format-Table Codespace, Worker, State, Model, Idle, Observed, Activity -AutoSize

    $running = $rows | Where-Object { $_.State -eq 'RUNNING' -and $_.Activity }
    if ($running) {
        Write-Host 'Running worker activity:'
        $running | Format-Table -Wrap -AutoSize Codespace, Worker, Activity
    }
}

switch ($Verb) {
    'codespaces' {
        Get-CodespaceList | ForEach-Object { Write-Host $_ }
    }

    'setup' {
        Invoke-Setup -Target (Resolve-Codespace)
    }

    'dashboard' {
        do {
            Write-Host ("Worker snapshot {0:yyyy-MM-dd HH:mm:ss K}" -f (Get-Date))
            Show-Dashboard
            if ($Watch) { Start-Sleep -Seconds 20 }
        } while ($Watch)
    }

    'status' {
        $target = Resolve-Codespace
        if ($Json) {
            & gh codespace ssh -c $target -- "python3 $RemoteRoot/worker-snapshot.py"
        }
        else {
            $arguments = @('status') + $Rest
            exit (Invoke-Remote -Target $target -Arguments $arguments)
        }
    }

    default {
        $known = @('start', 'logs', 'attach', 'wait', 'stop', 'prune',
                   'bootstrap', 'version')
        if ($Verb -notin $known) {
            Write-Error ("Unknown verb '$Verb'. Known: setup, start, status, logs, " +
                         "attach, wait, stop, prune, bootstrap, dashboard, " +
                         "codespaces, version.")
            exit 2
        }
        $target = Resolve-Codespace
        $arguments = @($Verb) + $Rest
        exit (Invoke-Remote -Target $target -Arguments $arguments)
    }
}
