Import-Module "$PSScriptRoot/../helpers/Common.Helpers.psm1"

Describe "Dotnet and tools" {
    BeforeAll {
        $env:PATH = "/etc/skel/.dotnet/tools:$($env:PATH)"
        $dotnetSDKs = dotnet --list-sdks | ConvertTo-Json
        $dotnetRuntimes = dotnet --list-runtimes | ConvertTo-Json
    }

    $dotnetVersions = (Get-ToolsetContent).dotnet.versions

    Context "Default" {
        It "Default Dotnet SDK is available" {
            "dotnet --version" | Should -ReturnZeroExitCode
        }
    }

    # Regression coverage for actions/runner-images#14462 (also #10989, #11419):
    # .NET aborts with "Couldn't find a valid ICU package installed on the system"
    # when libicu is missing. `dotnet --version` is answered by the host and does
    # not initialize globalization, so it keeps passing while `dotnet build` fails
    # at startup (CultureInfo/TimeZoneInfo). The checks below fail if ICU is absent.
    Context "Globalization (ICU)" {
        It "libicu is available to the dynamic loader" {
            "ldconfig -p | grep -E 'libicui18n\.so|libicuuc\.so'" | Should -ReturnZeroExitCode
        }

        It "dotnet initializes globalization without invariant mode" {
            "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0 dotnet build --help" | Should -ReturnZeroExitCode
        }
    }

    Context "Latest" {
        $latestVersion = @($dotnetVersions | Sort-Object { [Version] $_ })[-1]
        $dotnetLatest = @{ dotnetVersion = $latestVersion }

        It "Latest SDK <dotnetVersion> is available" -TestCases $dotnetLatest {
            $dotnetSDKs | Should -Match "$dotnetVersion.[1-9]*"
        }

        It "Default 'dotnet --version' resolves to the latest SDK <dotnetVersion>" -TestCases $dotnetLatest {
            (dotnet --version) | Should -BeLike "$dotnetVersion.*"
        }
    }

    foreach ($version in $dotnetVersions) {
        Context "Dotnet $version" {
            $dotnet = @{ dotnetVersion = $version }

            It "SDK <dotnetVersion> is available" -TestCases $dotnet {
                $dotnetSDKs | Should -Match "$dotnetVersion.[1-9]*"
            }

            It "Runtime <dotnetVersion> is available" -TestCases $dotnet {
                $dotnetRuntimes | Should -Match "$dotnetVersion.[1-9]*"
            }
        }
    }

    Context "Dotnet tools" {
        $dotnetTools = (Get-ToolsetContent).dotnet.tools
        $testCases = $dotnetTools | ForEach-Object { @{ ToolName = $_.name; TestInstance = $_.test }}

        It "<ToolName> is available" -TestCases $testCases {
            "$TestInstance" | Should -ReturnZeroExitCode
        }
    }
}
