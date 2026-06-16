# preview-server.Tests.ps1
#
# Pester v5 tests for the preview-environment resolver (Get-PreviewServerConfig /
# Get-BackendVenvPart in scripts/lib/_session-config.ps1) and the preview-server.ps1
# script contract. Run with: Invoke-Pester -Path . (from tests dir)

BeforeAll {
    $libDir = Join-Path $PSScriptRoot "..\scripts\lib"
    . (Join-Path $libDir "_session-config.ps1")

    $examplesDir = Join-Path $PSScriptRoot "..\examples"
    $script:MonorepoExample = (Resolve-Path (Join-Path $examplesDir "session-plugin.monorepo-split.json")).Path
    $script:RootExample     = (Resolve-Path (Join-Path $examplesDir "session-plugin.root.json")).Path
    $script:PreviewScript   = (Resolve-Path (Join-Path $PSScriptRoot "..\scripts\server\preview-server.ps1")).Path

    function Get-Cfg([string]$Path) { Get-Content $Path -Raw | ConvertFrom-Json }
}

Describe "Get-PreviewServerConfig — port derivation" {

    It "monorepo: frontend port = devServer.port + default offset (3000+100)" {
        $pv = Get-PreviewServerConfig -Config (Get-Cfg $script:MonorepoExample)
        $pv.frontendPort | Should -Be 3100
    }

    It "monorepo: backend port = 8000 (default base) + default offset = 8100" {
        $pv = Get-PreviewServerConfig -Config (Get-Cfg $script:MonorepoExample)
        $pv.backendPort | Should -Be 8100
    }

    It "root: frontend port derives from devServer.port (3000+100); no backend" {
        $pv = Get-PreviewServerConfig -Config (Get-Cfg $script:RootExample)
        $pv.frontendPort | Should -Be 3100
        $pv.hasBackend   | Should -BeFalse
        $pv.backendDir   | Should -BeNullOrEmpty
    }

    It "honors an explicit previewServer.portOffset" {
        $cfg = Get-Cfg $script:MonorepoExample
        $cfg | Add-Member -NotePropertyName previewServer -NotePropertyValue ([pscustomobject]@{ portOffset = 200 }) -Force
        $pv = Get-PreviewServerConfig -Config $cfg
        $pv.frontendPort | Should -Be 3200
        $pv.backendPort  | Should -Be 8200
        $pv.portOffset   | Should -Be 200
    }

    It "honors an explicit backend.basePort" {
        $cfg = Get-Cfg $script:MonorepoExample
        $cfg | Add-Member -NotePropertyName previewServer -NotePropertyValue ([pscustomobject]@{
            backend = [pscustomobject]@{ basePort = 9000 }
        }) -Force
        (Get-PreviewServerConfig -Config $cfg).backendPort | Should -Be 9100
    }
}

Describe "Get-PreviewServerConfig — worktree mapping" {

    It "defaults the worktree to the _preview dir under worktreesPath" {
        $cfg = Get-Cfg $script:MonorepoExample
        $pv  = Get-PreviewServerConfig -Config $cfg
        $pv.worktreeName | Should -Be "_preview"
        $pv.worktreePath | Should -Be (Join-Path $cfg.worktreesPath "_preview")
    }

    It "honors an explicit previewServer.worktreeName" {
        $cfg = Get-Cfg $script:MonorepoExample
        $cfg | Add-Member -NotePropertyName previewServer -NotePropertyValue ([pscustomobject]@{ worktreeName = "_review" }) -Force
        $pv = Get-PreviewServerConfig -Config $cfg
        $pv.worktreePath | Should -Be (Join-Path $cfg.worktreesPath "_review")
    }
}

Describe "Get-PreviewServerConfig — dirs + commands" {

    It "monorepo: frontend dir from devServer.dir; {port} substituted into the default devCmd" {
        $pv = Get-PreviewServerConfig -Config (Get-Cfg $script:MonorepoExample)
        $pv.frontendDir    | Should -Be "frontend"
        $pv.frontendDevCmd | Should -Be "npx next dev -p 3100 -H 0.0.0.0"
        $pv.frontendDevCmd.Contains('{port}') | Should -BeFalse
    }

    It "monorepo: backend dir + venv auto-derived from the layout part that declares pythonVenv" {
        $pv = Get-PreviewServerConfig -Config (Get-Cfg $script:MonorepoExample)
        $pv.hasBackend  | Should -BeTrue
        $pv.backendDir  | Should -Be "backend"
        $pv.backendVenv | Should -Be ".venv"
    }

    It "backend devCmd is null when unconfigured (no safe universal default)" {
        # Auto-derived backend (from the venv layout part) has dir+venv but NO devCmd
        # unless previewServer.backend.devCmd is set. Strip the example's previewServer
        # so this asserts the pure default-derivation path.
        $cfg = Get-Cfg $script:MonorepoExample
        $cfg.PSObject.Properties.Remove('previewServer')
        $pv = Get-PreviewServerConfig -Config $cfg
        $pv.hasBackend    | Should -BeTrue
        $pv.backendDevCmd | Should -BeNullOrEmpty
    }

    It "substitutes {port} into a configured backend devCmd with the derived backend port" {
        $cfg = Get-Cfg $script:MonorepoExample
        $cfg | Add-Member -NotePropertyName previewServer -NotePropertyValue ([pscustomobject]@{
            backend = [pscustomobject]@{ devCmd = ".venv\Scripts\python.exe -m uvicorn app.main:app --port {port}" }
        }) -Force
        $pv = Get-PreviewServerConfig -Config $cfg
        $pv.backendDevCmd | Should -Be ".venv\Scripts\python.exe -m uvicorn app.main:app --port 8100"
    }
}

Describe "Get-BackendVenvPart" {

    It "returns the venv-declaring part for a monorepo-split layout" {
        $part = Get-BackendVenvPart -Config (Get-Cfg $script:MonorepoExample)
        $part.name       | Should -Be "backend"
        $part.pythonVenv | Should -Be ".venv"
    }

    It "returns nothing for a root layout" {
        Get-BackendVenvPart -Config (Get-Cfg $script:RootExample) | Should -BeNullOrEmpty
    }
}

Describe "preview-server.ps1 contract" {

    It "exists" { Test-Path $script:PreviewScript | Should -BeTrue }

    It "parses with no errors" {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:PreviewScript, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because ((@($errors) | ForEach-Object { $_.Message }) -join '; ')
    }

    It "supports the four actions" {
        $body = Get-Content $script:PreviewScript -Raw
        $body | Should -Match '"start", "switch", "stop", "status"'
    }

    It "resolves a PR number to a branch via gh, and boots named psmux windows" {
        $body = Get-Content $script:PreviewScript -Raw
        $body | Should -Match 'gh pr view'
        $body | Should -Match 'headRefName'
        $body | Should -Match 'preview-fe'
        $body | Should -Match 'preview-be'
        $body | Should -Match 'psmux new-window'
    }

    It "does a REAL frontend install (detaches any stale junction) — not a junction" {
        $body = Get-Content $script:PreviewScript -Raw
        $body | Should -Match 'LinkType'      # detect + detach a stale junction
        $body | Should -Match 'rmdir'         # remove the link, not the target
        $body | Should -Match 'Get-DetectedInstall'
    }

    It "uses kill-port before booting and on stop" {
        (Get-Content $script:PreviewScript -Raw) | Should -Match 'kill-port\.ps1'
    }
}
