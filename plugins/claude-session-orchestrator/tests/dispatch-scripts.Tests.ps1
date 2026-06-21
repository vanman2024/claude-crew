# dispatch-scripts.Tests.ps1
#
# Pester v5 tests that every PowerShell script in the plugin parses cleanly
# (catches syntax regressions — e.g. in the launchers' here-string briefs), and
# that the reviewer launcher honors config.review.intervalMin.

BeforeAll {
    $script:ScriptsDir = (Resolve-Path (Join-Path $PSScriptRoot "..\scripts")).Path
    $script:ReviewerScript = Join-Path $script:ScriptsDir "dispatch\start-reviewer.ps1"
    $script:OrchScript     = Join-Path $script:ScriptsDir "dispatch\start-orchestrator.ps1"
    $script:CodexScript    = Join-Path $script:ScriptsDir "dispatch\dispatch-codex.ps1"
    $script:PsmuxScript    = Join-Path $script:ScriptsDir "dispatch\psmux-dispatch.ps1"
    $script:ConfigLib      = Join-Path $script:ScriptsDir "lib\_session-config.ps1"

    function Get-ParseErrors([string]$Path) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return @($errors)
    }
}

Describe "All plugin PowerShell scripts parse" {
    It "has no parse errors in <_>" -ForEach (Get-ChildItem (Resolve-Path (Join-Path $PSScriptRoot "..\scripts")).Path -Recurse -Filter *.ps1 | ForEach-Object { $_.FullName }) {
        $errs = Get-ParseErrors $_
        $errs.Count | Should -Be 0 -Because (($errs | ForEach-Object { $_.Message }) -join '; ')
    }
}

Describe "start-reviewer.ps1" {
    It "exists" {
        Test-Path $script:ReviewerScript | Should -BeTrue
    }

    It "declares the reviewer + review-checkout worktrees and the no-merge contract" {
        $body = Get-Content $script:ReviewerScript -Raw
        $body | Should -Match 'review-checkout'
        $body | Should -Match 'NEVER run ``gh pr merge``'
        $body | Should -Match 'checkout --detach'   # avoids the two-worktrees-one-branch conflict
    }

    It "resolves the interval from config.review.intervalMin when -IntervalMin not passed" {
        $body = Get-Content $script:ReviewerScript -Raw
        $body | Should -Match "review.*intervalMin"
        $body | Should -Match "PSBoundParameters.ContainsKey\('IntervalMin'\)"
    }
}

Describe "dispatch-codex.ps1 (headless build-ahead lane)" {
    It "exists" {
        Test-Path $script:CodexScript | Should -BeTrue
    }

    It "uses the verified headless codex exec flags + stdin prompt" {
        $body = Get-Content $script:CodexScript -Raw
        $body | Should -Match "exec"
        $body | Should -Match "--dangerously-bypass-approvals-and-sandbox"
        $body | Should -Match "--skip-git-repo-check"
        $body | Should -Match "--json"            # JSONL event stream
        $body | Should -Match "-o', \`$lastFile"   # final message captured to a file
    }

    It "provisions via the shared Initialize-WorkerWorktree (no drift with psmux-dispatch)" {
        (Get-Content $script:CodexScript -Raw) | Should -Match 'Initialize-WorkerWorktree'
    }

    It "resolves the codex command via Get-CodexCmd, not the interactive workerCmdPath" {
        (Get-Content $script:CodexScript -Raw) | Should -Match 'Get-CodexCmd'
    }
}

Describe "check-headless-workers.ps1 (headless monitor) classifies meta files" {
    BeforeAll {
        $script:MonitorScript = Join-Path $script:ScriptsDir "status\check-headless-workers.ps1"
        $script:TmpLogs = Join-Path ([IO.Path]::GetTempPath()) ("chw-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpLogs -Force | Out-Null

        # COMPLETE worker: dead pid, last.txt with the sentinel + a PR url.
        $doneLast = Join-Path $script:TmpLogs "done.last.txt"
        Set-Content $doneLast "WORKTREE_STATUS: COMPLETE`nPR: https://github.com/acme/repo/pull/42`n" -Encoding UTF8
        @{ name='done'; cli='codex'; pid=999999999; branch='feature/done'; last=$doneLast; stream=''; log='' } |
            ConvertTo-Json | Set-Content (Join-Path $script:TmpLogs "done.meta.json") -Encoding UTF8

        # EXITED worker: dead pid, no last.txt.
        @{ name='gone'; cli='codex'; pid=999999998; branch='feature/gone'; last=(Join-Path $script:TmpLogs 'gone.last.txt'); stream=''; log='' } |
            ConvertTo-Json | Set-Content (Join-Path $script:TmpLogs "gone.meta.json") -Encoding UTF8
    }
    AfterAll {
        if (Test-Path $script:TmpLogs) { Remove-Item $script:TmpLogs -Recurse -Force }
    }

    It "exists" { Test-Path $script:MonitorScript | Should -BeTrue }

    It "reports COMPLETE + the PR url, and EXITED for a dead worker with no result" {
        $json = & $script:MonitorScript -LogsDir $script:TmpLogs -Json
        $rows = $json | ConvertFrom-Json
        ($rows | Where-Object Name -eq 'done').State | Should -Be 'COMPLETE'
        ($rows | Where-Object Name -eq 'done').PR    | Should -Be 'https://github.com/acme/repo/pull/42'
        ($rows | Where-Object Name -eq 'gone').State | Should -Be 'EXITED'
    }
}

Describe "Shared worktree provisioning" {
    It "both dispatchers call Initialize-WorkerWorktree" {
        (Get-Content $script:PsmuxScript -Raw) | Should -Match 'Initialize-WorkerWorktree'
        (Get-Content $script:CodexScript -Raw) | Should -Match 'Initialize-WorkerWorktree'
    }

    It "the lib defines Initialize-WorkerWorktree and copies .mcp.json there (single source of truth)" {
        $lib = Get-Content $script:ConfigLib -Raw
        $lib | Should -Match 'function Initialize-WorkerWorktree'
        $lib | Should -Match '\.mcp\.json'
    }
}

Describe "Dispatch robustness: -NoProfile + git stderr (the 'session won't start' fix)" {
    It "the shared lib routes git stderr to stdout (GIT_REDIRECT_STDERR)" {
        $lib = Get-Content $script:ConfigLib -Raw
        $lib | Should -Match "GIT_REDIRECT_STDERR"
        $lib | Should -Match "'2>&1'"
    }

    It "no plugin .ps1 invokes powershell/pwsh -File without -NoProfile (would load the user profile / posh-git)" {
        $offenders = @()
        Get-ChildItem $script:ScriptsDir -Recurse -Filter *.ps1 | ForEach-Object {
            foreach ($line in (Get-Content $_.FullName)) {
                if ($line -match '(powershell(\.exe)? -ExecutionPolicy Bypass -File|pwsh -File)' -and $line -notmatch 'NoProfile') {
                    $offenders += ("{0}: {1}" -f $_.Name, $line.Trim())
                }
            }
        }
        $offenders -join "`n" | Should -BeNullOrEmpty
    }
}

Describe "psmux-dispatch.ps1 -Continue (resume mode)" {
    BeforeAll { $script:PsmuxBody = Get-Content $script:PsmuxScript -Raw }

    It "declares the -Continue and -NoNudge switches" {
        $script:PsmuxBody | Should -Match '\[switch\]\$Continue'
        $script:PsmuxBody | Should -Match '\[switch\]\$NoNudge'
    }

    It "uses the verified per-CLI resume invocations (claude --continue / codex resume --last)" {
        $script:PsmuxBody | Should -Match "'codex'\s*\{\s*'resume --last'"
        $script:PsmuxBody | Should -Match "'claude'\s*\{\s*'--continue'"
    }

    It "skips re-provisioning in continue mode and requires the worktree to already exist" {
        # Initialize-WorkerWorktree must be gated behind the NON-continue branch
        $script:PsmuxBody | Should -Match 'Continue mode: reusing existing worktree'
        $script:PsmuxBody | Should -Match 'nothing to resume'
    }

    It "sends a resume nudge (not the first-time bootstrap) unless -NoNudge" {
        $script:PsmuxBody | Should -Match 'resume nudge'
        $script:PsmuxBody | Should -Match 'was interrupted'
    }
}

Describe "restore-session.ps1 (crash recovery)" {
    BeforeAll {
        $script:RestoreScript = Join-Path $script:ScriptsDir "dispatch\restore-session.ps1"
        $script:RestoreBody   = Get-Content $script:RestoreScript -Raw
    }

    It "exists and parses" {
        Test-Path $script:RestoreScript | Should -BeTrue
        (Get-ParseErrors $script:RestoreScript).Count | Should -Be 0
    }

    It "attaches (no rebuild) when the psmux session is still alive" {
        $script:RestoreBody | Should -Match 'is ALIVE'
        $script:RestoreBody | Should -Match 'SESSION_ALIVE='
        $script:RestoreBody | Should -Match 'psmux attach -t'
    }

    It "discovers worktrees via git worktree list and skips the _preview env" {
        $script:RestoreBody | Should -Match 'git -C \$RepoRoot worktree list --porcelain'
        $script:RestoreBody | Should -Match "_preview"
    }

    It "re-dispatches each worktree through psmux-dispatch -Continue" {
        $script:RestoreBody | Should -Match 'psmux-dispatch.ps1'
        $script:RestoreBody | Should -Match "'-Continue'"
    }

    It "passes -NoNudge through when -Idle is set" {
        $script:RestoreBody | Should -Match '\[switch\]\$Idle'
        $script:RestoreBody | Should -Match "if \(\`$Idle\) \{ \`$dispatchArgs \+= '-NoNudge'"
    }
}

Describe "start-orchestrator.ps1 auto-launches the reviewer" {
    It "has a -NoReviewer opt-out switch" {
        $body = Get-Content $script:OrchScript -Raw
        $body | Should -Match '\[switch\]\$NoReviewer'
    }

    It "invokes start-reviewer.ps1 unless opted out" {
        $body = Get-Content $script:OrchScript -Raw
        $body | Should -Match 'start-reviewer.ps1'
        $body | Should -Match 'if \(-not \$NoReviewer\)'
    }

    It "excludes the reviewer infra worktrees from the batch" {
        $body = Get-Content $script:OrchScript -Raw
        $body | Should -Match 'review-checkout'
    }
}
