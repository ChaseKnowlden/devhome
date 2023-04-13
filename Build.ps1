Param(
    [string]$Platform = "x64",
    [string]$Configuration = "Debug",
    [string]$SDKVersion,
    [string]$SDKNugetSource,
    [string]$Version,
    [string]$BuildStep = "all",
    [string]$AzureBuildingBranch = "main",
    [switch]$IsAzurePipelineBuild = $false,
    [switch]$Help = $false
)

$StartTime = Get-Date

if ($Help) {
    Write-Host @"
Copyright (c) Microsoft Corporation and Contributors.
Licensed under the MIT License.

Syntax:
      Build.cmd [options]

Description:
      Builds Dev Home.

Options:

  -Platform <platform>
      Only buil the selected platform(s)
      Example: -Platform x64
      Example: -Platform "x86,x64,arm64"

  -Configuration <configuration>
      Only build the selected configuration(s)
      Example: -Configuration Release
      Example: -Configuration "Debug,Release"

  -Help
      Display this usage message.
"@
  Exit
}

$env:Build_RootDirectory = (Split-Path $MyInvocation.MyCommand.Path)
$env:Build_Platform = $Platform.ToLower()
$env:Build_Configuration = $Configuration.ToLower()
$env:msix_version = build\Scripts\CreateBuildInfo.ps1 -Version $Version -IsAzurePipelineBuild $IsAzurePipelineBuild
$env:sdk_version = build\Scripts\CreateBuildInfo.ps1 -Version $SDKVersion -IsSdkVersion $true -IsAzurePipelineBuild $IsAzurePipelineBuild

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')

if (($BuildStep -ieq "all") -Or ($BuildStep -ieq "sdk")) {
  pluginsdk\Build.ps1 -SDKVersion $env:sdk_version -IsAzurePipelineBuild $IsAzurePipelineBuild
}

$msbuildPath = &"${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -prerelease -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe
if ($IsAzurePipelineBuild) {
  $nugetPath = "nuget.exe";
} else {
  $nugetPath = (Join-Path $env:Build_RootDirectory "build\NugetWrapper.cmd")
}

$ErrorActionPreference = "Stop"

# Install NuGet Cred Provider
Invoke-Expression "& { $(irm https://aka.ms/install-artifacts-credprovider.ps1) } -AddNetfx"

if (-not([string]::IsNullOrWhiteSpace($SDKNugetSource))) {
  & $nugetPath sources add -Source $SDKNugetSource
}

. build\Scripts\CertSignAndInstall.ps1

Try {
  if (($BuildStep -ieq "all") -Or ($BuildStep -ieq "msix")) {
    [Reflection.Assembly]::LoadWithPartialName("System.Xml.Linq")
    $xIdentity = [System.Xml.Linq.XName]::Get("{http://schemas.microsoft.com/appx/manifest/foundation/windows10}Identity");
    $xProperties = [System.Xml.Linq.XName]::Get("{http://schemas.microsoft.com/appx/manifest/foundation/windows10}Properties");
    $xDisplayName = [System.Xml.Linq.XName]::Get("{http://schemas.microsoft.com/appx/manifest/foundation/windows10}DisplayName");

    # Update the appxmanifest
    $appxmanifestPath = (Join-Path $env:Build_RootDirectory "src\Package.appxmanifest")
    $appxmanifest = [System.Xml.Linq.XDocument]::Load($appxmanifestPath)
    $appxmanifest.Root.Element($xIdentity).Attribute("Version").Value = $env:msix_version
    if ($AzureBuildingBranch -ieq "release") {
      $appxmanifest.Root.Element($xIdentity).Attribute("Name").Value = "Microsoft.Windows.DevHome"
      $appxmanifest.Root.Element($xProperties).Element($xDisplayName).Value = "Dev Home (Preview)"
    } elseif ($AzureBuildingBranch -ieq "staging") {
      $appxmanifest.Root.Element($xIdentity).Attribute("Name").Value = "Microsoft.Windows.DevHome.Canary"
      $appxmanifest.Root.Element($xProperties).Element($xDisplayName).Value = "Dev Home (Canary)"
    }
    $appxmanifest.Save($appxmanifestPath)

    foreach ($platform in $env:Build_Platform.Split(",")) {
      foreach ($configuration in $env:Build_Configuration.Split(",")) {
        $appxPackageDir = (Join-Path $env:Build_RootDirectory "AppxPackages\$configuration")
        $msbuildArgs = @(
            ("DevHome.sln"),
            ("/p:Platform="+$platform),
            ("/p:Configuration="+$configuration),
            ("/p:DevHomeSDKVersion="+$env:sdk_version),
            ("/restore"),
            ("/binaryLogger:DevHome.$platform.$configuration.binlog"),
            ("/p:AppxPackageOutput=$appxPackageDir\DevHome-$platform.msix"),
            ("/p:AppxPackageSigningEnabled=false"),
            ("/p:GenerateAppxPackageOnBuild=true")
        )

        & $msbuildPath $msbuildArgs
        if (-not($IsAzurePipelineBuild) -And $isAdmin) {
          Invoke-SignPackage "$appxPackageDir\DevHome-$platform.msix"
        }
      }
    }

    # Reset the appxmanifest to prevent unnecessary code changes
    $appxmanifest = [System.Xml.Linq.XDocument]::Load($appxmanifestPath)
    $appxmanifest.Root.Element($xIdentity).Attribute("Version").Value = "0.0.0.0"
    $appxmanifest.Root.Element($xIdentity).Attribute("Name").Value = "Microsoft.Windows.DevHome.Dev"
    $appxmanifest.Root.Element($xProperties).Element($xDisplayName).Value = "Dev Home (Dev)"
    $appxmanifest.Save($appxmanifestPath)
  }

  if (($BuildStep -ieq "all") -Or ($BuildStep -ieq "msixbundle")) {
    foreach ($configuration in $env:Build_Configuration.Split(",")) {
      .\build\scripts\Create-AppxBundle.ps1 -InputPath (Join-Path $env:Build_RootDirectory "AppxPackages\$configuration") -ProjectName DevHome -BundleVersion ([version]$env:msix_version) -OutputPath (Join-Path $env:Build_RootDirectory ("AppxBundles\$configuration\DevHome_" + $env:msix_version + "_8wekyb3d8bbwe.msixbundle"))
      if (-not($IsAzurePipelineBuild) -And $isAdmin) {
        Invoke-SignPackage ("AppxBundles\$configuration\DevHome_" + $env:msix_version + "_8wekyb3d8bbwe.msixbundle")
      }
    }
  }
} Catch {
  $formatString = "`n{0}`n`n{1}`n`n"
  $fields = $_, $_.ScriptStackTrace
  Write-Host ($formatString -f $fields) -ForegroundColor RED
  Exit 1
}

$TotalTime = (Get-Date)-$StartTime
$TotalMinutes = [math]::Floor($TotalTime.TotalMinutes)
$TotalSeconds = [math]::Ceiling($TotalTime.TotalSeconds) - ($totalMinutes * 60)

if (-not($isAdmin)) {
  Write-Host @"

WARNING: Cert signing requires admin privileges.  To sign, run the following in an elevated Developer Command Prompt.
"@ -ForegroundColor GREEN
  foreach ($platform in $env:Build_Platform.Split(",")) {
    foreach ($configuration in $env:Build_Configuration.Split(",")) {
      $appxPackageFile = (Join-Path $env:Build_RootDirectory "AppxPackages\$configuration\DevHome-$platform.msix")
        Write-Host @"
powershell -command "& { . build\scripts\CertSignAndInstall.ps1; Invoke-SignPackage $appxPackageFile }"
"@ -ForegroundColor GREEN
    }
  }
}

Write-Host @"

Total Running Time:
$TotalMinutes minutes and $TotalSeconds seconds
"@ -ForegroundColor CYAN