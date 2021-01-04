<#
.Synopsis
	Build script invoked by Invoke-Build.

.Description
	TODO: Declare build parameters as standard script parameters. Parameters
	are specified directly for Invoke-Build if their names do not conflict.
	Otherwise or alternatively they are passed in as "-Parameters @{...}".
#>

# TODO: [CmdletBinding()] is optional but recommended for strict name checks.
[CmdletBinding()]
param(
)
# PSake makes variables declared here available in other scriptblocks
# Init some things
# TODO: Move some properties to script param() in order to use as parameters.

    # Find the build folder based on build system
    $ProjectRoot = $ENV:BHProjectPath
    if(-not $ProjectRoot)
    {
        $ProjectRoot = (Resolve-Path -Path "$PSScriptRoot\.." -ErrorAction Stop).Path
    }

    $Timestamp = Get-date -uformat "%Y%m%d-%H%M%S"
    $PSVersion = $PSVersionTable.PSVersion.Major
    $TestFileFormat = "TestResults_PS$PSVersion`_$TimeStamp.xml"
    $lines = '----------------------------------------------------------------------'

    $Verbose = @{}
    if($ENV:BHCommitMessage -match "!verbose")
    {
        $Verbose = @{Verbose = $True}
    }

# TODO: Default task. If it is the first then any name can be used instead.
task . Deploy

task Init {
    $lines
    Set-Location $ProjectRoot
    "Build System Details:"
    Get-Item ENV:BH*
    "`n"
}

task Test Init, {
    $lines

    foreach ($TestType in @('Unit','Integration'))
    {
        "`n`tSTATUS: $TestType testing with PowerShell $PSVersion"
        $TestFile = "{0}_{1}" -f $TestType, $TestFileFormat

        if (Test-Path -Path "$ProjectRoot\Tests\$TestType")
        {
            # Gather test results. Store them in a variable and file
            $TestResults = Invoke-Pester -Path "$ProjectRoot\Tests\$TestType" -PassThru -OutputFormat NUnitXml -OutputFile "$ProjectRoot\$TestFile"

            # In Appveyor?  Upload our tests! #Abstract this into a function?
            If($ENV:BHBuildSystem -eq 'AppVeyor')
            {
                (New-Object 'System.Net.WebClient').UploadFile(
                    "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)",
                    "$ProjectRoot\$TestFile" )
            }

            Remove-Item "$ProjectRoot\$TestFile" -Force -ErrorAction SilentlyContinue

            # Failed tests?
            # Need to tell psake or it will proceed to the deployment. Danger!
            if($TestResults.FailedCount -gt 0)
            {
                throw "Failed '$($TestResults.FailedCount)' $TestType tests, build failed"
                break # break out if any of the test fails
            }
            "`n"
        }
    }
}

task Build Test, {
    $lines

    Set-Location $ProjectRoot
    # Load the module, read the exported functions, update the psd1 FunctionsToExport
    Set-ModuleFunctions

    # Bump the module version
    Try
    {
        [Version]$Version = Get-NextNugetPackageVersion -Name $env:BHProjectName -PackageSourceUrl 'https://NuGET.dev.iconic-it.com/Nuget' -ErrorAction Stop
        [Version]$LocalVersion  = Get-Metadata -Path $env:BHPSModuleManifest -PropertyName ModuleVersion
        $Build    = if($Version.Build    -lt 0) { 0 } else { $Version.Build + 1 }
        if ($LocalVersion.Build -gt $Version.Build) {$Build = $LocalVersion.Build}
        $Revision = if($Version.Revision -lt 0) { 1 } else { $LocalVersion.Revision + 1 }
        if ($LocalVersion -ge $Version) {
            $Version = $LocalVersion
        }
        $Version  = New-Object System.Version ($Version.Major, $Version.Minor, $Build, $Revision)
        # write-Verbose "BHProjectName      - $env:BHProjectName" -Verbose
        write-Verbose "Version            - $Version" -Verbose
        # write-Verbose "BHPSModuleManifest - $env:BHPSModuleManifest" -Verbose

        Update-Metadata -Path $env:BHPSModuleManifest -PropertyName ModuleVersion -Value $Version -ErrorAction stop
    }
    Catch
    {
        "Failed to update version for '$env:BHProjectName': $_.`nContinuing with existing version"
    }
}

task Deploy Build, {
    $lines

    $Params = @{
        Path = $ProjectRoot
        Force = $true
        Recurse = $false # We keep psdeploy artifacts, avoid deploying those : )
        Beta = $true
        FeedUrl = $Credentials.NuGet.FeedUrl
        ApiKey = $Credentials.NuGet.ApiKey

    }
    . C:\Projects\GitHub\PSPostMan\PSPostMan.ps1
    Invoke-PSDeploy @Verbose @Params
}

