# worker-cli-profile.Tests.ps1
#
# Pester v5 tests for Get-WorkerCliProfile in scripts/lib/_session-config.ps1 —
# the data-driven worker-CLI launch/handshake profile. Run: Invoke-Pester -Path .

BeforeAll {
    $libDir = Join-Path $PSScriptRoot "..\scripts\lib"
    . (Join-Path $libDir "_session-config.ps1")
    $examplesDir = Join-Path $PSScriptRoot "..\examples"
    $script:Mono = (Resolve-Path (Join-Path $examplesDir "session-plugin.monorepo-split.json")).Path

    # Build a config object from the monorepo example, optionally attaching a
    # workerCli value parsed from a JSON snippet.
    function New-Cfg {
        param([string]$WorkerCliJson)
        $cfg = Get-Content $script:Mono -Raw | ConvertFrom-Json
        if ($WorkerCliJson) {
            $wc = $WorkerCliJson | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName workerCli -NotePropertyValue $wc -Force
        }
        return $cfg
    }
}

Describe "Get-WorkerCliProfile" {

    Context "default (no workerCli)" {
        It "resolves the claude preset with cmd from workerCmdPath" {
            $cfg = New-Cfg
            $p = Get-WorkerCliProfile -Config $cfg
            $p.name | Should -Be 'claude'
            $p.cmd  | Should -Be $cfg.workerCmdPath
            $p.args | Should -Contain '--dangerously-skip-permissions'
            $p.clearEnv | Should -Contain 'CLAUDECODE'
            $p.clearEnv | Should -Contain 'CLAUDE_CODE_ENTRYPOINT'
            $p.acceptSend | Should -Be '2'
            $p.readyMatchAny | Should -Contain 'bypasspermissionson'
        }
    }

    Context "string preset" {
        It "claude string is equivalent to the default" {
            $cfg = New-Cfg; $cfg | Add-Member workerCli 'claude' -Force
            (Get-WorkerCliProfile -Config $cfg).name | Should -Be 'claude'
        }

        It "generic has no args/env/patterns and a fixed bootWait, cmd falls back" {
            $cfg = New-Cfg; $cfg | Add-Member workerCli 'generic' -Force
            $p = Get-WorkerCliProfile -Config $cfg
            $p.name | Should -Be 'generic'
            @($p.args).Count | Should -Be 0
            @($p.clearEnv).Count | Should -Be 0
            @($p.acceptMatchAny).Count | Should -Be 0
            @($p.readyMatchAny).Count | Should -Be 0
            $p.bootWaitSec | Should -Be 10
            $p.cmd | Should -Be $cfg.workerCmdPath
        }

        It "an unknown preset name throws" {
            $cfg = New-Cfg; $cfg | Add-Member workerCli 'nope' -Force
            { Get-WorkerCliProfile -Config $cfg } | Should -Throw "*Unknown workerCli preset*"
        }
    }

    Context "object override" {
        It "extends a preset, overrides every field, honors explicit cmd" {
            $json = '{ "preset": "generic", "cmd": "C:\\x\\codex.cmd", "args": ["--auto"], "clearEnv": ["FOO"], "accept": { "matchAny": ["trustthisfolder?"], "send": "y" }, "ready": { "matchAny": ["readytoken"] }, "bootWaitSec": 20 }'
            $cfg = New-Cfg $json
            $p = Get-WorkerCliProfile -Config $cfg
            $p.cmd | Should -Be 'C:\x\codex.cmd'
            ($p.args -join ',')        | Should -Be '--auto'
            ($p.clearEnv -join ',')    | Should -Be 'FOO'
            ($p.acceptMatchAny -join ',') | Should -Be 'trustthisfolder?'
            $p.acceptSend | Should -Be 'y'
            ($p.readyMatchAny -join ',')  | Should -Be 'readytoken'
            $p.bootWaitSec | Should -Be 20
        }

        It "an object without cmd falls back to workerCmdPath" {
            $cfg = New-Cfg '{ "preset": "generic", "args": ["--x"] }'
            (Get-WorkerCliProfile -Config $cfg).cmd | Should -Be $cfg.workerCmdPath
        }

        It "an object with no preset defaults to extending claude" {
            $cfg = New-Cfg '{ "args": ["--only"] }'
            $p = Get-WorkerCliProfile -Config $cfg
            $p.name | Should -Be 'claude'
            ($p.args -join ',') | Should -Be '--only'
            # claude preset bits it did NOT override survive:
            $p.clearEnv | Should -Contain 'CLAUDECODE'
        }
    }
}
