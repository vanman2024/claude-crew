# slug.Tests.ps1
#
# Pester v5 tests for ConvertTo-SessionSlug in scripts/lib/_session-config.ps1.

BeforeAll {
    $libDir = Join-Path $PSScriptRoot "..\scripts\lib"
    . (Join-Path $libDir "_session-config.ps1")
}

Describe "ConvertTo-SessionSlug" {

    It "lowercases and replaces non-alphanumerics with single hyphens" {
        ConvertTo-SessionSlug -Text "Fix the Login Bug!" | Should -Be "fix-the-login-bug"
    }

    It "trims leading and trailing junk" {
        ConvertTo-SessionSlug -Text "  !!!Hello World!!!  " | Should -Be "hello-world"
    }

    It "collapses runs of non-alphanumerics to a single hyphen" {
        ConvertTo-SessionSlug -Text "foo___---   bar///baz" | Should -Be "foo-bar-baz"
    }

    It "truncates to <= MaxLength and leaves no trailing hyphen" {
        $long = "This is a really long issue title that goes well beyond forty characters in total"
        $slug = ConvertTo-SessionSlug -Text $long
        $slug.Length | Should -BeLessOrEqual 40
        $slug | Should -Not -Match '-$'
    }

    It "respects a custom MaxLength without a trailing hyphen" {
        # "aaaa bbbb" -> "aaaa-bbbb"; substring(0,5) = "aaaa-" -> trimmed -> "aaaa"
        ConvertTo-SessionSlug -Text "aaaa bbbb" -MaxLength 5 | Should -Be "aaaa"
    }

    It "returns 'task' for symbols-only input" {
        ConvertTo-SessionSlug -Text "!!!@@@###" | Should -Be "task"
    }

    It "returns 'task' for whitespace-only input" {
        ConvertTo-SessionSlug -Text "     " | Should -Be "task"
    }

    It "keeps existing digits and single hyphens" {
        ConvertTo-SessionSlug -Text "Issue 510 - patch v2" | Should -Be "issue-510-patch-v2"
    }
}
