# brief-generation.Tests.ps1
#
# Pester v5 tests for the brief generators in scripts/lib/_session-brief.ps1
# (Format-TeamsSection, New-WorkerBrief). Depends on _session-config.ps1 helpers.

BeforeAll {
    $libDir = Join-Path $PSScriptRoot "..\scripts\lib"
    . (Join-Path $libDir "_session-config.ps1")
    . (Join-Path $libDir "_session-brief.ps1")

    $examplesDir = Join-Path $PSScriptRoot "..\examples"
    $script:MonorepoExample = (Resolve-Path (Join-Path $examplesDir "session-plugin.monorepo-split.json")).Path

    function Get-MonorepoConfig {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName "_configPath" -NotePropertyValue $script:MonorepoExample -Force
        return $cfg
    }
}

Describe "Format-TeamsSection" {

    Context "with teams declared" {
        BeforeAll {
            $script:Section = Format-TeamsSection -Config (Get-MonorepoConfig)
        }

        It "renders the configured agent names" {
            $script:Section | Should -Match 'nextjs-frontend:component-builder-agent'
            $script:Section | Should -Match 'fastapi-backend:endpoint-generator-agent'
        }

        It "renders team names and owned paths" {
            $script:Section | Should -Match '### Team: frontend'
            $script:Section | Should -Match '### Team: backend'
            $script:Section | Should -Match 'Owns paths'
            $script:Section | Should -Match 'frontend/components/\*\*'
        }

        It "renders skills when present" {
            $script:Section | Should -Match 'frontend-design'
            $script:Section | Should -Match 'design-system-enforcement'
        }

        It "includes the NEVER general-purpose rule" {
            # .Contains avoids regex; the code emits single backticks around general-purpose.
            $script:Section.Contains('NEVER `general-purpose`') | Should -BeTrue
            $script:Section.Contains('Do NOT use `general-purpose`') | Should -BeTrue
        }

        It "includes the BLOCKED agent-unavailable rule" {
            # Literal match — a '<agent>' regex makes Pester try to expand $agent.
            $script:Section.Contains('BLOCKED: <agent> unavailable') | Should -BeTrue
        }
    }

    Context "without teams" {
        It "returns the single-Claude fallback when teams property is removed" {
            $cfg = Get-MonorepoConfig
            $cfg.PSObject.Properties.Remove('teams')
            $section = Format-TeamsSection -Config $cfg
            $section | Should -Match 'Build approach: single-Claude'
            $section | Should -Match 'has not declared specialized agent teams'
            $section | Should -Not -Match '### Team:'
        }

        It "returns the fallback when teams is null" {
            $cfg = Get-MonorepoConfig
            $cfg.teams = $null
            $section = Format-TeamsSection -Config $cfg
            $section | Should -Match 'Build approach: single-Claude'
        }
    }
}

Describe "New-WorkerBrief" {

    BeforeAll {
        $script:Cfg = Get-MonorepoConfig
        $script:TaskText = "Implement the password reset flow end to end."
    }

    It "includes the branch in the header and the git commands" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText
        $brief | Should -Match 'feat/pw-reset'
        $brief | Should -Match 'git push -u origin feat/pw-reset'
    }

    It "includes the task text" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText
        $brief | Should -Match 'Implement the password reset flow end to end\.'
    }

    It "includes the configured test commands" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText
        $brief | Should -Match 'npx tsc --noEmit'
        $brief | Should -Match 'pytest'
    }

    It "emits the WORKTREE_STATUS COMPLETE and BLOCKED sentinels" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText
        $brief | Should -Match 'WORKTREE_STATUS: COMPLETE'
        $brief | Should -Match 'WORKTREE_STATUS: BLOCKED'
    }

    It "adds 'Closes #510' when -IssueNumber is given" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText -IssueNumber 510
        $brief | Should -Match 'Closes #510'
    }

    It "omits the Closes line when no -IssueNumber" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText
        $brief | Should -Not -Match 'Closes #'
    }

    It "includes the project name and a title line when -Title given" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText -Title "Password reset"
        $brief | Should -Match 'RedAI'
        $brief | Should -Match '\*\*Task:\*\* Password reset'
    }
}
