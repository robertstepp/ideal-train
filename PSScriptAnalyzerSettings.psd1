@{
    # PSScriptAnalyzer settings for File Checker.
    #
    # This file only CONFIGURES rules -- it deliberately does not set
    # IncludeRules or ExcludeRules, so the full default rule set still runs.
    # Rules that are deliberately silenced are suppressed at the point of use,
    # via SuppressMessageAttribute in the .ps1 with a stated justification,
    # rather than being switched off for the whole repository here.
    #
    # The filename is the one the VS Code PowerShell extension looks for at the
    # workspace root, so editor and CI check the same thing.
    Rules = @{

        # PSUseCompatibleSyntax does nothing at all unless TargetVersions is
        # supplied -- it is in the default rule set but silently no-ops when
        # unconfigured. Naming both supported hosts makes it report syntax that
        # only parses on one of them.
        #
        # The script declares '#Requires -Version 5.1' and its README states
        # support for Windows PowerShell 5.1 (.NET Framework) and PowerShell 7+
        # (.NET Core). Nothing previously verified that claim.
        #
        # Targeting 5.1 flags PowerShell 7-only syntax as an Error: the ternary
        # operator '? :', null-coalescing '??' and '??=', and the pipeline chain
        # operators '&&' and '||'. Those parse fine in 7 and are a hard parse
        # failure in 5.1, so they would break the script for anyone launching it
        # with powershell.exe -- which is the form the usage examples show.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @(
                '5.1',   # Windows PowerShell, the documented minimum
                '7.0'    # PowerShell 7, the other documented host
            )
        }
    }
}
