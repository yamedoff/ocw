# ocw

Run bounded OpenCode workers in a GitHub Codespace and drive them from your own
machine with one command.

`ocw` exists because delegating work to a remote machine is only useful if you
can see what it is doing. It gives each worker a name, a durable state
directory, a bounded log, and a single verb to start, watch, and stop it. Your
laptop stays free, and the workers never touch your local checkout.

## Two parts

```
ocw/
  remote/     runs inside the Codespace    ocw, worker-snapshot.py, setup-worktrees.sh
  local/      runs on your machine         ocw.ps1
  tests/      self-test, no Codespace needed
```

**`remote/ocw`** owns worker lifecycle. It launches one OpenCode process per
worker, keeps that worker's state on disk, and reports status. It only runs
inside the Codespace.

**`local/ocw.ps1`** is the half you actually type. It proxies every verb over
`gh codespace ssh`, so you never hand-write a remote command, and it adds
`setup`, which installs the remote payload into a Codespace.

OpenCode itself only runs in the Codespace. The local half never runs a model.

## Requirements

- [GitHub CLI](https://cli.github.com/) authenticated with the `codespace`
  scope: `gh auth login`
- A Codespace, started
- At least one OpenCode provider authenticated inside the Codespace. `setup`
  installs and upgrades the OpenCode binary itself.
- PowerShell 5.1+ on your machine

## Setup

```powershell
git clone https://github.com/yamedoff/ocw.git
cd ocw

# See what you have
./local/ocw.ps1 codespaces

# Install the remote half into a Codespace
./local/ocw.ps1 -Codespace <codespace-name> setup
```

`setup` packages `remote/` and sends it over SSH, so the Codespace does not need
the repository cloned. It then runs `bootstrap`, which installs OpenCode when it
is missing and upgrades it when it is present, and prints the version it ended
up with.

Run `bootstrap` on its own whenever you want to refresh the binary:

```powershell
./local/ocw.ps1 bootstrap                  # install when missing, upgrade when present
./local/ocw.ps1 bootstrap --install-only   # leave a present binary alone
./local/ocw.ps1 bootstrap --upgrade-only   # refuse when missing, do not install
```

`start` installs a missing binary but never upgrades mid-flight, so a run is not
surprised by a version change.

If you only have one Codespace, you can skip `-Codespace` everywhere. Otherwise
set it once per shell:

```powershell
$env:OCW_CODESPACE = '<codespace-name>'
```

## Use

Create a worktree per lane first, so workers never share a checkout:

```powershell
gh codespace ssh -c <codespace-name> -- "/home/codespace/remote-package/setup-worktrees.sh /workspaces/<repo> /workspaces/worktrees feature/lane-a"
```

Then start a worker. `PROMPT` is a file path, or literal text when no such file
exists:

```powershell
./local/ocw.ps1 start lane-a opencode-go/deepseek-v4.1-flash high `
    /workspaces/worktrees/feature-lane-a "lane a" ./prompt-lane-a.md
```

Watch it, follow it, or wait for it:

```powershell
./local/ocw.ps1 status                 # every worker
./local/ocw.ps1 status lane-a          # one worker, with exit code
./local/ocw.ps1 status --json          # machine-readable
./local/ocw.ps1 attach lane-a          # follow, rendered as concise lines
./local/ocw.ps1 logs lane-a 40         # raw log tail
./local/ocw.ps1 wait lane-a 900        # exit 0 when done, 1 when failed
```

Across Codespaces:

```powershell
./local/ocw.ps1 dashboard              # one table, cached against SSH blips
./local/ocw.ps1 dashboard -Watch       # refresh every 20s
```

Clean up finished lanes:

```powershell
./local/ocw.ps1 prune                  # finished workers only
./local/ocw.ps1 prune lane-a           # one worker, refused if running
./local/ocw.ps1 stop lane-a            # ask a running worker to terminate
```

## How state works

Worker state lives outside any repository, at `$HOME/.local/state/ocw-workers`
inside the Codespace, so logs and prompts never become product commits. Each
worker directory holds its pid, start time, exit code, model, variant, worktree,
title, prompt, attachments, and raw output log.

State is derived from the process first, then the recorded exit code. A worker
killed by a restart therefore reads `STOPPED`, not a stale `DONE`. The states
are `RUNNING`, `DONE`, `FAILED`, `STOPPED`, and `MISSING`.

Override the location with `OCW_STATE_ROOT` if you keep state elsewhere.

### Parallel workers

OpenCode keeps its SQLite database beside provider authentication in the XDG
data directory. Two workers sharing that directory contend on one database and
fail with `database is locked`.

`ocw` gives every worker its own `XDG_DATA_HOME` and symlinks only the shared
`auth.json`, so parallel lanes each get a private database and one shared login.

### Model routing

`MODEL` is a provider-qualified slug, and `VARIANT` is that provider's reasoning
effort. Both are passed straight through, so verify slugs against the installed
Codespace rather than guessing:

```powershell
gh codespace ssh -c <codespace-name> -- "opencode models"
```

## Security notes

- The remote payload loads the Codespace's managed token from
  `/workspaces/.codespaces/shared/.env` for Git operations. That token is never
  written into a prompt, a log, or the console.
- `attach` and the snapshot reader redact credential-shaped text and cap every
  summary, so routine monitoring cannot flood your terminal or your context.
- Raw worker output is OpenCode JSONL and may contain file contents or command
  output. Treat `logs` output as sensitive, and `prune` lanes you no longer need.
- Workers run with `--auto`, which auto-approves permissions that are not
  explicitly denied. Keep the destructive-action prohibitions in your prompts.

## Self-test

No Codespace, no network, and no model. It exercises state derivation, exit
codes, prune safety, and argument validation against a temporary state root:

```bash
bash tests/selftest.sh
```

## License

MIT. See [LICENSE](LICENSE).
