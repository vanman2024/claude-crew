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
