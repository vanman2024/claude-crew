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

Describe "Dispatch robustness: Windows PowerShell 5.1 (npm EBADENGINE killed dispatch mid-install)" {
    It "the shared lib refuses to load under Windows PowerShell 5.1, with a pwsh re-run hint" -Skip:(-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $out = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { . '$script:ConfigLib'; 'LOADED' } catch { `$_.Exception.Message }"
        ($out -join "`n") | Should -Not -Match 'LOADED'
        ($out -join "`n") | Should -Match 'requires PowerShell 7 \(pwsh\)'
    }

    It "the per-worktree install redirects inside cmd, not with a PowerShell-side *> / 2>" {
        $lib = Get-Content $script:ConfigLib -Raw
        $lib | Should -Not -Match 'cmd /c \$install\s*[*2]>'
        $lib | Should -Match 'cmd /c "\$install > `"\$installLog`" 2>&1"'
    }

    It "no skill/reference doc or script tells the caller to launch via powershell.exe" {
        $pluginRoot = Split-Path $script:ScriptsDir -Parent
        $offenders = Get-ChildItem $pluginRoot -Recurse -Include *.md, *.ps1 |
            Where-Object { $_.Name -ne 'CHANGELOG.md' -and $_.FullName -notmatch '\\tests\\' } |
            Select-String -Pattern 'powershell\.exe\s+-' |
            ForEach-Object { "{0}:{1}: {2}" -f $_.Filename, $_.LineNumber, $_.Line.Trim() }
        $offenders -join "`n" | Should -BeNullOrEmpty
    }
}

Describe "One skill per role (conductor / orchestrator / reviewer)" {
    BeforeAll {
        $script:PluginRoot = Split-Path $script:ScriptsDir -Parent
        $script:SkillsDir  = Join-Path $script:PluginRoot "skills"
        function Get-SkillText([string]$Name) { Get-Content (Join-Path $script:SkillsDir "$Name\SKILL.md") -Raw }
    }

    It "<_> skill exists and its frontmatter name matches its folder" -ForEach @('session', 'orchestrate', 'review') {
        (Get-SkillText $_) | Should -Match "(?m)^name: $_\s*$"
    }

    It "the conductor skill decides its role from .claude-bootstrap.md and takes the conductor role without it" {
        $s = Get-SkillText 'session'
        $s | Should -Match 'Which role are you'
        $s | Should -Match '\.claude-bootstrap\.md'
        $s | Should -Match 'you are the \*\*conductor\*\*'
    }

    It "the conductor skill covers <_>" -ForEach @('status', 'plan', 'relay', 'local', 'merge', 'pull', 'done', 'launch') {
        (Get-SkillText 'session') | Should -Match "(?m)^## ``$_"
    }

    It "the conductor watches the terminals (status watchdog loop), but never runs a per-worker monitor loop" {
        $s = Get-SkillText 'session'
        $s | Should -Not -Match '/loop \S+ /\S*session monitor'
        $s | Should -Match '/loop 10m /crew:session status'
        $s | Should -Match 'check-crew-health\.ps1'
    }

    It "the conductor relays through send-to-worker.ps1, not a bare send-keys with a message" {
        $s = Get-SkillText 'session'
        $s | Should -Match 'send-to-worker\.ps1'
        $s | Should -Not -Match 'psmux send-keys -t <sess>:<name> "<message>"'
    }

    It "the conductor merges into the RESOLVED base and checks each PR's base first" {
        $s = Get-SkillText 'session'
        $s | Should -Match 'resolve-config\.ps1'
        $s | Should -Match 'gh pr edit <n> --base <base>'
    }

    It "the <_> skill sends a non-owner back to /crew:session" -ForEach @('orchestrate', 'review') {
        $s = Get-SkillText $_
        $s | Should -Match '\.claude-bootstrap\.md'
        $s | Should -Match '/crew:session'
    }

    It "the orchestrator brief runs /crew:orchestrate poll, in its /loop too" {
        $body = Get-Content $script:OrchScript -Raw
        $body | Should -Match '``/crew:orchestrate poll``'
        $body | Should -Match '/loop \$\{IntervalMin\}m /crew:orchestrate poll'
    }

    It "the reviewer brief runs /crew:review, in its /loop too" {
        $body = Get-Content $script:ReviewerScript -Raw
        $body | Should -Match '``/crew:review``'
        $body | Should -Match '/loop \$\{IntervalMin\}m /crew:review'
    }

    It "the orchestrator never tears workers down (brief + its reference)" {
        $brief = Get-Content $script:OrchScript -Raw
        $brief | Should -Not -Match 'CloseWorkerScript'
        $brief | Should -Match 'NEVER tear down a worker'
        $ref = Get-Content (Join-Path $script:SkillsDir "orchestrate\reference\commands-orchestrate.md") -Raw
        $ref | Should -Not -Match 'close-worker\.ps1"? -Name'
        $ref | Should -Not -Match 'tear down via `close-worker'
    }

    It "nothing still calls the old /session orchestrate|monitor|review form" {
        $offenders = Get-ChildItem $script:PluginRoot -Recurse -Include *.md, *.ps1 |
            Where-Object { $_.Name -ne 'CHANGELOG.md' -and $_.FullName -notmatch '\\tests\\' } |
            Select-String -Pattern '/session (orchestrate|monitor|review)\b' |
            ForEach-Object { "{0}:{1}: {2}" -f $_.Filename, $_.LineNumber, $_.Line.Trim() }
        $offenders -join "`n" | Should -BeNullOrEmpty
    }

    It "every relative link in the skills resolves to a file" {
        $broken = foreach ($md in (Get-ChildItem $script:SkillsDir -Recurse -Filter *.md)) {
            foreach ($m in [regex]::Matches((Get-Content $md.FullName -Raw), '\]\(([^)#:\s]+\.md)(#[^)]*)?\)')) {
                $target = Join-Path $md.DirectoryName $m.Groups[1].Value
                if (-not (Test-Path $target)) { "{0} -> {1}" -f $md.FullName.Substring($script:SkillsDir.Length), $m.Groups[1].Value }
            }
        }
        $broken -join "`n" | Should -BeNullOrEmpty
    }
}

Describe "Orchestrator + reviewer launch with transcript saving on" {
    It "<_> clears CLAUDE_CODE_CHILD_SESSION and forces session persistence" -ForEach @('start-orchestrator.ps1', 'start-reviewer.ps1') {
        $body = Get-Content (Join-Path $script:ScriptsDir "dispatch\$_") -Raw
        $body | Should -Match '\$env:CLAUDE_CODE_CHILD_SESSION=\$null'
        $body | Should -Match "\`$env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=''1''"
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

Describe "Get-PaneState (the watchdog's pane classifier)" {
    BeforeAll { . (Join-Path $PSScriptRoot "..\scripts\lib\_session-config.ps1") }

    It "a bare pwsh prompt at the bottom means the CLI exited" {
        (Get-PaneState -Lines @("some output", "", "PS C:\Users\me\proj>")).State | Should -Be "exited"
    }

    It "an empty pane counts as exited" {
        (Get-PaneState -Lines @("", "  ")).State | Should -Be "exited"
    }

    It "typed-but-unsent input in Claude's box is pending, with the text in Detail (seen live)" {
        $pane = @(
            "✻ Cooked for 11s · done 2:16 AM",
            "────────────────────",
            "❯ WaitforCIonce1e085andreportback",
            "────────────────────",
            "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
        )
        $v = Get-PaneState -Lines $pane
        $v.State  | Should -Be "pending"
        $v.Detail | Should -Match 'WaitforCIonce1e085andreportback'
    }

    It "an empty input box with the footer is running" {
        $pane = @("● Done.", "────────", "❯ ", "────────", "  ⏵⏵ bypass permissions on (shift+tab to cycle)")
        (Get-PaneState -Lines $pane).State | Should -Be "running"
    }

    It "an old submitted prompt far above the bottom is not mistaken for pending input" {
        $pane = @("❯ build the intake form") + @(1..10 | ForEach-Object { "working line $_" }) + @("❯ ", "  ⏵⏵ bypass permissions on")
        (Get-PaneState -Lines $pane).State | Should -Be "running"
    }
}

Describe "Spec -> issues: plan never invents, and the spec reaches the worker" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\scripts\lib\_session-config.ps1")
        . (Join-Path $PSScriptRoot "..\scripts\lib\_session-brief.ps1")
        $script:PlanRef = Get-Content (Join-Path $PSScriptRoot "..\skills\session\reference\commands-plan.md") -Raw
    }

    It "reads Spec and Work type from a planned issue's header" {
        $body = "Spec: specs/intake.md`nSpec section: §4 Form`nWork type: feature`nLane: frontend`n`n## What the spec says`n> ..."
        $h = Get-IssueBriefHints -Body $body
        $h.Spec | Should -Be "specs/intake.md"
        $h.Mode | Should -Be "feature"
    }

    It "accepts bolded and backticked header lines" {
        $h = Get-IssueBriefHints -Body "**Spec:** ``docs/specs/f012-billing.md```n**Work type:** Iteration"
        $h.Spec | Should -Be "docs/specs/f012-billing.md"
        $h.Mode | Should -Be "iteration"
    }

    It "returns nothing for an ordinary issue, so the old default still applies" {
        $h = Get-IssueBriefHints -Body "The login button is misaligned on mobile.`nSteps: ..."
        $h.Spec | Should -BeNullOrEmpty
        $h.Mode | Should -BeNullOrEmpty
    }

    It "a planned issue briefs the worker to build to the spec as a feature, not an iteration" {
        $cfg = Get-Content (Join-Path $PSScriptRoot "..\examples\session-plugin.root.json") -Raw | ConvertFrom-Json
        $h = Get-IssueBriefHints -Body "Spec: specs/intake.md`nWork type: feature"
        $brief = New-WorkerBrief -Config $cfg -Name "fix-12-intake" -Branch "fix/12-intake" -Task "t" -IssueNumber 12 -Spec $h.Spec -Mode $h.Mode
        $brief | Should -Match 'NEW FEATURE'
        $brief | Should -Match 'specs/intake\.md'
    }

    It "the bulk dispatcher passes the issue's hints into the brief" {
        $body = Get-Content (Join-Path $PSScriptRoot "..\scripts\dispatch\psmux-dispatch-issues.ps1") -Raw
        $body | Should -Match 'Get-IssueBriefHints'
    }

    It "plan's rules: silence in the spec becomes an open question, never a made-up value" {
        $script:PlanRef | Should -Match 'Never make criteria up'
        $script:PlanRef | Should -Match 'open question'
        $script:PlanRef | Should -Match 'needs-decision'
    }

    It "plan shows the plan and creates nothing until the user says go" {
        $script:PlanRef | Should -Match 'create nothing yet'
    }

    It "plan creates issues with --body-file (inline bodies got mangled)" {
        $script:PlanRef | Should -Match '--body-file'
    }
}

Describe "Overseer launch: boot handshake + same plugin copy (found by dogfooding)" {
    BeforeAll { . (Join-Path $PSScriptRoot "..\scripts\lib\_session-config.ps1") }

    It "a pane stuck on the folder-trust screen is 'dialog', not running (captured live)" {
        $pane = @(
            "Accessingworkspace:",
            "C:\...\app-worktrees\orchestrator",
            "Quicksafetycheck:Isthisaprojectyoucreatedoroneyoutrust?",
            "Securityguide",
            "❯No,exit",
            "Yes,Itrustthisfolder",
            "Entertoconfirm·Esctocancel"
        )
        (Get-PaneState -Lines $pane).State | Should -Be "dialog"
    }

    It "<_> waits on the shared boot handshake instead of a blind sleep" -ForEach @('start-orchestrator.ps1', 'start-reviewer.ps1', 'psmux-dispatch.ps1') {
        $body = Get-Content (Join-Path $PSScriptRoot "..\scripts\dispatch\$_") -Raw
        $body | Should -Match 'Wait-CliReady -Target'
        $body | Should -Not -Match 'Start-Sleep -Seconds 8'
    }

    It "<_> launches Claude with --plugin-dir of its own plugin copy" -ForEach @('start-orchestrator.ps1', 'start-reviewer.ps1', 'psmux-dispatch.ps1', 'dispatch-worktree.ps1') {
        (Get-Content (Join-Path $PSScriptRoot "..\scripts\dispatch\$_") -Raw) | Should -Match 'Get-PluginDirArg'
    }

    It "Get-PluginRoot resolves to the folder holding this plugin's manifest" {
        Test-Path (Join-Path (Get-PluginRoot) ".claude-plugin\plugin.json") | Should -BeTrue
        Get-PluginDirArg | Should -Match '^--plugin-dir ".+claude-session-orchestrator"$'
    }
}

Describe "Boot handshake answers first-run screens by navigation (captured live)" {
    BeforeAll { . (Join-Path $PSScriptRoot "..\scripts\lib\_session-config.ps1") }

    It "the claude preset answers folder trust and the bypass warning by choosing an option, not by sending a digit" {
        $p = Get-WorkerCliPreset -Name 'claude'
        @($p.acceptScreens | ForEach-Object { $_.choose }) | Should -Contain 'Yes,Itrustthisfolder'
        @($p.acceptScreens | ForEach-Object { $_.choose }) | Should -Contain 'Yes,Iaccept'
        # "2" + Enter on the unnumbered trust screen picked "No, exit" and quit Claude.
        $p.acceptSend | Should -BeNullOrEmpty
    }

    It "Wait-CliReady presses Down until the chosen option is highlighted, then Enter" {
        $frames = [System.Collections.Generic.Queue[object]]::new()
        $frames.Enqueue(@(" Security guide", " ❯ No, exit", "   Yes, I trust this folder", " Enter to confirm · Esc to cancel"))
        $frames.Enqueue(@(" Security guide", "   No, exit", " ❯ Yes, I trust this folder", " Enter to confirm · Esc to cancel"))
        $frames.Enqueue(@("❯ ", "  ⏵⏵ bypass permissions on (shift+tab to cycle)"))
        $sent = [System.Collections.Generic.List[string]]::new()
        # A stub defined here is what Wait-CliReady resolves (dynamic scoping), so no
        # psmux is needed on the test machine.
        function psmux {
            if ($args[0] -eq 'capture-pane') { return $frames.Dequeue() }
            if ($args[0] -eq 'send-keys') { $sent.Add(($args[3..($args.Count - 1)] -join ' ')) }
        }
        Mock Start-Sleep {}
        $r = Wait-CliReady -Target 't:w' -Cli (Get-WorkerCliPreset -Name 'claude') -MaxWaitSec 30 6>$null
        $r.Ready | Should -BeTrue
        ($sent -join ',') | Should -Be 'Down,Enter'
    }

    It "the idle placeholder hint in Claude's input line is not unsent input (captured live)" {
        $pane = @("● security: hooks.json: unknown key ""notes"" ignored", "────", "❯ Try ""how do I log an error?""", "────", "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents")
        (Get-PaneState -Lines $pane).State | Should -Be "running"
    }
}

Describe "Messages are sent through the verified path, not a bare send-keys + Enter (found by dogfooding)" {
    It "<_> submits with C-m" -ForEach @('psmux-dispatch.ps1', 'send-to-worker.ps1', 'start-orchestrator.ps1', 'start-reviewer.ps1') {
        # A single blind submit left every brief in a live launch sitting unsent.
        $offenders = Get-Content (Join-Path $PSScriptRoot "..\scripts\dispatch\$_") |
            Where-Object { $_ -match '^\s*(if \(.*\) \{ )?psmux send-keys .*\bEnter\b' }
        $offenders -join "`n" | Should -BeNullOrEmpty
    }

    It "the overseers nudge workers through send-to-worker.ps1" -ForEach @('start-orchestrator.ps1', 'start-reviewer.ps1') {
        (Get-Content (Join-Path $PSScriptRoot "..\scripts\dispatch\$_") -Raw) | Should -Match 'send-to-worker\.ps1'
    }

    It "no skill tells anyone to nudge with a bare send-keys ... Enter" {
        $offenders = Get-ChildItem (Join-Path $PSScriptRoot "..\skills") -Recurse -Filter *.md |
            Select-String -Pattern 'send-keys -t <sess>:<\w+> "[^"]*" Enter' |
            ForEach-Object { "{0}:{1}" -f $_.Filename, $_.LineNumber }
        $offenders -join "`n" | Should -BeNullOrEmpty
    }
}

Describe "Send-PaneMessage: see the text, submit, retry until it leaves the box (captured live)" {
    BeforeAll { . (Join-Path $PSScriptRoot "..\scripts\lib\_session-config.ps1") }

    It "waits past the empty-box render lag, and retries the eaten first submit" {
        $R = '────────────────────────────────────────'
        $frames = [System.Collections.Generic.Queue[object]]::new()
        $frames.Enqueue(@($R, "❯", $R, "  ⏵⏵ bypass permissions on"))                                                  # text not drawn yet
        $frames.Enqueue(@($R, "❯ Read .claude-bootstrap.md and follow it exactly.", "", $R, "  ⏵⏵ bypass permissions on"))  # text visible
        $frames.Enqueue(@($R, "❯ Read .claude-bootstrap.md and follow it exactly.", "", $R, "  ⏵⏵ bypass permissions on"))  # 1st C-m eaten
        $frames.Enqueue(@("✢ Gusting…", $R, "❯", $R, "  ⏵⏵ bypass permissions on · esc to interrupt"))                  # 2nd C-m went
        $sent = [System.Collections.Generic.List[string]]::new()
        function psmux {
            if ($args[0] -eq 'capture-pane') { return $frames.Dequeue() }
            if ($args[0] -eq 'send-keys') { $sent.Add($args[-1]) }
        }
        Mock Start-Sleep {}
        Send-PaneMessage -Target 't:w' -Text "Read .claude-bootstrap.md and follow it exactly." 6>$null | Should -BeTrue
        ($sent -join ' | ') | Should -Be 'Read .claude-bootstrap.md and follow it exactly. | C-m | C-m'
    }

    It "an empty box before the text has appeared is NOT success (the bug that passed a stuck brief)" {
        $R = '────────────────────────────────────────'
        Get-InputBoxText -Lines @($R, "❯", $R) | Should -Be ""
        Get-InputBoxText -Lines @($R, "❯ Read .claude-bootstrap.md", "", $R) | Should -Be "Read.claude-bootstrap.md"
        Get-InputBoxText -Lines @($R, "❯ Try ""how do I log an error?""", $R) | Should -Be ""
        Get-InputBoxText -Lines @("no box here") | Should -BeNullOrEmpty
    }

    It "<_> sends its brief through Send-PaneMessage" -ForEach @('psmux-dispatch.ps1', 'start-orchestrator.ps1', 'start-reviewer.ps1', 'send-to-worker.ps1') {
        (Get-Content (Join-Path $PSScriptRoot "..\scripts\dispatch\$_") -Raw) | Should -Match 'Send-PaneMessage -Target'
    }
}
Describe "Test-InputSubmitted needs positive evidence (captured live)" {
    BeforeAll { . (Join-Path $PSScriptRoot "..\scripts\lib\_session-config.ps1") }

    It "busy footer counts as submitted" {
        Test-InputSubmitted -Lines @("✽ Levitating… (1m 18s)", "❯", "  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt") | Should -BeTrue
    }
    It "an empty box counts as submitted" {
        Test-InputSubmitted -Lines @("● Done.", "❯ ", "  ⏵⏵ bypass permissions on") | Should -BeTrue
    }
    It "text still in the box is not submitted" {
        Test-InputSubmitted -Lines @("❯ Read .claude-bootstrap.md and follow it exactly.", "  ⏵⏵ bypass permissions on") | Should -BeFalse
    }
    It "startup output with the input line out of view is NOT taken as submitted" {
        Test-InputSubmitted -Lines @("● planning: hooks.json: unknown key ""notes"" ignored", "● agents-md: no CLAUDE.md found; AGENTS.md loaded") | Should -BeFalse
    }
}
