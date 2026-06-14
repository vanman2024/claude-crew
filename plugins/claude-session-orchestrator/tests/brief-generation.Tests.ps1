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

Describe "Format-DataFlowSection" {

    Context "with dataFlow declared as an object" {
        BeforeAll {
            $script:Section = Format-DataFlowSection -Config (Get-MonorepoConfig)
        }

        It "renders the canonical entities and flows" {
            $script:Section | Should -Match 'CANONICAL data-flow map'
            $script:Section | Should -Match 'User, Order, Payment, Receipt, Notification'
            $script:Section | Should -Match 'Payment success -> Order.status = paid'
        }

        It "renders the notes when present" {
            $script:Section | Should -Match 'One Order per checkout'
        }

        It "always includes the no-new-entities rails" {
            $script:Section | Should -Match 'Rails \(non-negotiable\)'
            $script:Section.Contains('Do NOT') | Should -BeTrue
            $script:Section.Contains('second version of something') | Should -BeTrue
        }
    }

    Context "with dataFlow declared as a string" {
        It "renders the raw string and the rails" {
            $cfg = Get-MonorepoConfig
            $cfg.dataFlow = 'user -> order -> payment -> db -> receipt'
            $section = Format-DataFlowSection -Config $cfg
            $section | Should -Match 'user -> order -> payment -> db -> receipt'
            $section | Should -Match 'Rails \(non-negotiable\)'
        }
    }

    Context "without dataFlow" {
        It "returns the map-it-yourself fallback when the property is removed" {
            $cfg = Get-MonorepoConfig
            $cfg.PSObject.Properties.Remove('dataFlow')
            $section = Format-DataFlowSection -Config $cfg
            $section | Should -Match 'write a 60-second data-flow map'
            $section | Should -Not -Match 'CANONICAL data-flow map'
            $section | Should -Match 'Rails \(non-negotiable\)'
        }

        It "returns the fallback when dataFlow is null" {
            $cfg = Get-MonorepoConfig
            $cfg.dataFlow = $null
            $section = Format-DataFlowSection -Config $cfg
            $section | Should -Match 'write a 60-second data-flow map'
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

    It "embeds the data-flow map step before the plan step" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "pw-reset" -Branch "feat/pw-reset" -Task $script:TaskText
        $brief | Should -Match '## 3\. Map the data flow'
        $brief | Should -Match '## 4\. Plan first'
        $brief | Should -Match 'CANONICAL data-flow map'
        # the map must come before the plan step
        $mapIdx  = $brief.IndexOf('Map the data flow')
        $planIdx = $brief.IndexOf('Plan first')
        ($mapIdx -lt $planIdx -and $mapIdx -ge 0) | Should -BeTrue
    }
}

Describe "Format-WorkTypeSection (the two work types)" {

    It "feature + spec: build TO the spec as source of truth" {
        $s = Format-WorkTypeSection -Mode feature -Spec 'specs/booking/spec.md'
        $s | Should -Match 'NEW FEATURE'
        $s | Should -Match 'SOURCE OF TRUTH'
        $s | Should -Match 'specs/booking/spec\.md'
    }

    It "feature without a spec: nudges to get/write one" {
        $s = Format-WorkTypeSection -Mode feature
        $s | Should -Match 'NEW FEATURE'
        $s | Should -Match 'no spec path was provided'
    }

    It "iteration + spec: spec is CONTEXT/reference, existing code is the baseline" {
        $s = Format-WorkTypeSection -Mode iteration -Spec 'specs/booking/spec.md'
        $s | Should -Match 'ITERATION'
        $s | Should -Match 'REFERENCE'
        $s | Should -Match 'do not rebuild'
        $s | Should -Match 'specs/booking/spec\.md'
    }

    It "iteration without a spec: still says change-existing-only" {
        $s = Format-WorkTypeSection -Mode iteration
        $s | Should -Match 'ITERATION'
        $s | Should -Match 'do not rebuild'
    }

    It "rejects an unknown mode" {
        { Format-WorkTypeSection -Mode rewrite } | Should -Throw
    }
}

Describe "New-WorkerBrief work-type wiring" {

    BeforeAll {
        $script:Cfg = Get-MonorepoConfig
        $script:TaskText = "Mobile-optimize the settings pages."
    }

    It "defaults to FEATURE when there is no issue" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "x" -Branch "feat/x" -Task $script:TaskText
        $brief | Should -Match '## 0\. Work type: NEW FEATURE'
    }

    It "defaults to ITERATION when -IssueNumber is given" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "x" -Branch "fix/x" -Task $script:TaskText -IssueNumber 578
        $brief | Should -Match '## 0\. Work type: ITERATION'
    }

    It "injects the -Spec path and honors an explicit -Mode" {
        $brief = New-WorkerBrief -Config $script:Cfg -Name "x" -Branch "fix/x" -Task $script:TaskText -IssueNumber 578 -Mode iteration -Spec 'specs/settings/spec.md'
        $brief | Should -Match 'specs/settings/spec\.md'
        $brief | Should -Match 'ITERATION'
        # section 0 comes before section 1
        ($brief.IndexOf('## 0. Work type') -lt $brief.IndexOf('## 1. Orient')) | Should -BeTrue
    }
}
