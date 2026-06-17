# config-resolution.Tests.ps1
#
# Pester v5 tests for the config loader + path helpers in
# scripts/lib/_session-config.ps1 (and a couple of helpers it provides that
# _session-brief.ps1 relies on). Run with: Invoke-Pester -Path . (from tests dir)

BeforeAll {
    $libDir = Join-Path $PSScriptRoot "..\scripts\lib"
    . (Join-Path $libDir "_session-config.ps1")
    . (Join-Path $libDir "_session-brief.ps1")

    $examplesDir = Join-Path $PSScriptRoot "..\examples"
    $script:MonorepoExample = (Resolve-Path (Join-Path $examplesDir "session-plugin.monorepo-split.json")).Path
    $script:RootExample     = (Resolve-Path (Join-Path $examplesDir "session-plugin.root.json")).Path

    # Helper: create a fake project on a temp dir with .claude\session-plugin.json
    # seeded from one of the example shapes. Returns the project root path.
    function New-FakeProject {
        param(
            [Parameter(Mandatory)][ValidateSet('monorepo', 'root')]$Shape,
            [string]$Root
        )
        if (-not $Root) {
            $Root = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-test-" + [System.Guid]::NewGuid().ToString('N'))
        }
        $claudeDir = Join-Path $Root ".claude"
        New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
        $src = if ($Shape -eq 'monorepo') { $script:MonorepoExample } else { $script:RootExample }
        Copy-Item -Path $src -Destination (Join-Path $claudeDir "session-plugin.json") -Force
        return $Root
    }
}

Describe "Find-SessionConfigPath" {

    Context "explicit -Config" {
        It "returns the resolved path when the file exists" {
            $root = New-FakeProject -Shape root
            $cfgPath = Join-Path $root ".claude\session-plugin.json"
            $result = Find-SessionConfigPath -Config $cfgPath
            $result | Should -Be ((Resolve-Path $cfgPath).Path)
        }

        It "throws when the -Config path does not exist" {
            { Find-SessionConfigPath -Config "Z:\nope\does-not-exist.json" } |
                Should -Throw "*not found*"
        }
    }

    Context "explicit -RepoPath" {
        It "finds .claude\session-plugin.json under the repo" {
            $root = New-FakeProject -Shape monorepo
            $result = Find-SessionConfigPath -RepoPath $root
            $result | Should -Be ((Resolve-Path (Join-Path $root ".claude\session-plugin.json")).Path)
        }

        It "throws when no config under -RepoPath" {
            $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-empty-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            { Find-SessionConfigPath -RepoPath $empty } | Should -Throw "*No .claude*"
        }
    }

    Context "walk-up discovery from -Start" {
        It "discovers the config by walking up from a nested subdir" {
            $root = New-FakeProject -Shape root
            $nested = Join-Path $root "a\b\c"
            New-Item -ItemType Directory -Path $nested -Force | Out-Null
            $result = Find-SessionConfigPath -Start $nested
            $result | Should -Be ((Resolve-Path (Join-Path $root ".claude\session-plugin.json")).Path)
        }

        It "throws when nothing is found walking up to the drive root" {
            # A temp dir with no .claude anywhere above it that we control. We use a
            # fresh temp tree; if a parent happens to contain a config this would be
            # flaky, so we assert the call either finds nothing (throws) gracefully.
            $bare = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-bare-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $bare -Force | Out-Null
            # Only assert throw if no ancestor has a config (typical temp dir).
            $hasAncestorConfig = $false
            $d = (Resolve-Path $bare).Path
            while ($d) {
                if (Test-Path (Join-Path $d ".claude\session-plugin.json")) { $hasAncestorConfig = $true; break }
                $p = Split-Path $d -Parent
                if ($p -eq $d) { break }
                $d = $p
            }
            if (-not $hasAncestorConfig) {
                { Find-SessionConfigPath -Start $bare } | Should -Throw "*Could not find*"
            }
        }
    }
}

Describe "Get-SessionConfig" {

    Context "successful load" {
        It "parses the monorepo example and sets _configPath" {
            $root = New-FakeProject -Shape monorepo
            $cfg = Get-SessionConfig -RepoPath $root
            $cfg.projectName | Should -Be "RedAI"
            $cfg.layout.type | Should -Be "monorepo-split"
            $cfg._configPath | Should -Be ((Resolve-Path (Join-Path $root ".claude\session-plugin.json")).Path)
        }

        It "parses the root example and sets _configPath" {
            $root = New-FakeProject -Shape root
            $cfg = Get-SessionConfig -RepoPath $root
            $cfg.projectName | Should -Be "StaffHive"
            $cfg.layout.type | Should -Be "root"
            $cfg._configPath | Should -Not -BeNullOrEmpty
        }
    }

    Context "validation failures" {
        It "throws when a required field is missing" {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-bad-" + [System.Guid]::NewGuid().ToString('N'))
            $claudeDir = Join-Path $root ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            # Missing 'repoPath'
            @{
                projectName   = "X"
                worktreesPath = "w"
                psmuxSession  = "x"
                githubRepo    = "o/r"
                defaultBranch = "main"
                workerCmdPath = "c"
                layout        = @{ type = "root" }
            } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $claudeDir "session-plugin.json")
            { Get-SessionConfig -RepoPath $root } | Should -Throw "*missing required field 'repoPath'*"
        }

        It "throws on a bad layout.type" {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-badtype-" + [System.Guid]::NewGuid().ToString('N'))
            $claudeDir = Join-Path $root ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            @{
                projectName   = "X"
                repoPath      = "r"
                worktreesPath = "w"
                psmuxSession  = "x"
                githubRepo    = "o/r"
                defaultBranch = "main"
                workerCmdPath = "c"
                layout        = @{ type = "polyrepo" }
            } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $claudeDir "session-plugin.json")
            { Get-SessionConfig -RepoPath $root } | Should -Throw "*layout.type must be*"
        }

        It "throws when layout has no type" {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-notype-" + [System.Guid]::NewGuid().ToString('N'))
            $claudeDir = Join-Path $root ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            @{
                projectName   = "X"
                repoPath      = "r"
                worktreesPath = "w"
                psmuxSession  = "x"
                githubRepo    = "o/r"
                defaultBranch = "main"
                workerCmdPath = "c"
                layout        = @{ envFiles = @(".env") }
            } | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $claudeDir "session-plugin.json")
            { Get-SessionConfig -RepoPath $root } | Should -Throw "*layout is missing 'type'*"
        }

        It "throws on invalid JSON" {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sess-badjson-" + [System.Guid]::NewGuid().ToString('N'))
            $claudeDir = Join-Path $root ".claude"
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            Set-Content -Path (Join-Path $claudeDir "session-plugin.json") -Value "{ not valid json "
            { Get-SessionConfig -RepoPath $root } | Should -Throw "*Failed to parse*"
        }
    }
}

Describe "Get-EnvFileMappings" {

    It "monorepo-split: joins part.path with each env file, backslash-normalized" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $result = @(Get-EnvFileMappings -Config $cfg)
        $result | Should -Be @('frontend\.env.local', 'frontend\.env.test', 'backend\.env')
    }

    It "root: returns repo-relative env files" {
        $cfg = Get-Content $script:RootExample -Raw | ConvertFrom-Json
        $result = @(Get-EnvFileMappings -Config $cfg)
        $result | Should -Be @('.env', '.env.local', '.env.test')
    }
}

Describe "Get-NodeModuleMappings" {

    It "monorepo-split: returns each part's nodeModules, backslash-normalized" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $result = @(Get-NodeModuleMappings -Config $cfg)
        $result | Should -Be @('frontend\node_modules')
    }

    It "root: returns the single nodeModules entry" {
        $cfg = Get-Content $script:RootExample -Raw | ConvertFrom-Json
        $result = @(Get-NodeModuleMappings -Config $cfg)
        $result | Should -Be @('node_modules')
    }
}

Describe "Get-WorktreeDepsMode" {

    It "reads worktreeDeps=install from the example templates" {
        (Get-WorktreeDepsMode -Config (Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json)) | Should -Be "install"
        (Get-WorktreeDepsMode -Config (Get-Content $script:RootExample     -Raw | ConvertFrom-Json)) | Should -Be "install"
    }

    It "defaults to junction when the key is absent (backward compatible)" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $cfg.PSObject.Properties.Remove('worktreeDeps')
        (Get-WorktreeDepsMode -Config $cfg) | Should -Be "junction"
    }

    It "falls back to junction for an unknown value" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $cfg.worktreeDeps = "bogus"
        (Get-WorktreeDepsMode -Config $cfg) | Should -Be "junction"
    }

    It "is case-insensitive on the install value" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $cfg.worktreeDeps = "INSTALL"
        (Get-WorktreeDepsMode -Config $cfg) | Should -Be "install"
    }
}

Describe "Get-DetectedInstallCmd" {

    It "picks the package manager from the lockfile present" {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("inst-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            New-Item -ItemType File -Path (Join-Path $dir "pnpm-lock.yaml") | Out-Null
            Get-DetectedInstallCmd -Dir $dir | Should -Be "pnpm install"
            Remove-Item (Join-Path $dir "pnpm-lock.yaml")
            New-Item -ItemType File -Path (Join-Path $dir "yarn.lock") | Out-Null
            Get-DetectedInstallCmd -Dir $dir | Should -Be "yarn install"
            Remove-Item (Join-Path $dir "yarn.lock")
            New-Item -ItemType File -Path (Join-Path $dir "package-lock.json") | Out-Null
            Get-DetectedInstallCmd -Dir $dir | Should -Be "npm install"
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It "defaults to pnpm install when no lockfile is present" {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("inst-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try { Get-DetectedInstallCmd -Dir $dir | Should -Be "pnpm install" }
        finally { Remove-Item $dir -Recurse -Force }
    }
}

Describe "Get-TestCommands" {

    It "monorepo-split: returns one name/cmd object per part" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $cmds = @(Get-TestCommands -Config $cfg)
        $cmds.Count | Should -Be 2
        $cmds[0].name | Should -Be "frontend"
        $cmds[0].cmd  | Should -Be "cd frontend && npx tsc --noEmit && pnpm test"
        $cmds[1].name | Should -Be "backend"
    }

    It "monorepo-split: substitutes the repo placeholder with repoPath in the backend testCmd" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $cmds = @(Get-TestCommands -Config $cfg)
        $backend = $cmds | Where-Object { $_.name -eq "backend" }
        $backend.cmd | Should -Be "& '$($cfg.repoPath)\backend\.venv\Scripts\python.exe' -m pytest"
        # .Contains avoids regex; a '<repo>' pattern makes Pester try to expand $repo.
        $backend.cmd.Contains('<repo>') | Should -BeFalse
    }

    It "root: returns a single command named after the project" {
        $cfg = Get-Content $script:RootExample -Raw | ConvertFrom-Json
        $cmds = @(Get-TestCommands -Config $cfg)
        $cmds.Count | Should -Be 1
        $cmds[0].name | Should -Be "StaffHive"
        $cmds[0].cmd  | Should -Be "npx tsc --noEmit && pnpm test"
    }
}

Describe "Get-WorktreePath / Get-PsmuxTarget" {

    It "Get-WorktreePath joins worktreesPath and name" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        $result = Get-WorktreePath -Config $cfg -Name "fix-login"
        $result | Should -Be (Join-Path $cfg.worktreesPath "fix-login")
    }

    It "Get-PsmuxTarget formats session:window" {
        $cfg = Get-Content $script:MonorepoExample -Raw | ConvertFrom-Json
        Get-PsmuxTarget -Config $cfg -Name "fix-login" | Should -Be "redai:fix-login"
    }
}

