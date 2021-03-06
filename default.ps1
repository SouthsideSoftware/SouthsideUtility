properties {
  $revision =  if ("$env:BUILD_NUMBER".length -gt 0) { "$env:BUILD_NUMBER" } else { "0" }
  $inTeamCity = if ("$env:BUILD_NUMBER".length -gt 0) { $true } else { $false }
  $version = "0.26.0"
  $configuration = "Debug"
  $platform = "Any CPU"
  $buildOutputDir = "./BuildOutput"
  $nugetOutputDir = Join-Path $buildOutputDir "nuget"
  $testAssemblies = @()
  $dllOutputsToPublish = @("SouthsideUtility.Core","SouthsideUtility.RavenDB", "SouthsideUtility.Testing")
  $nugetPackagesToPublish = @("SouthsideUtility.Core","SouthsideUtility.RavenDB", "SouthsideUtility.Testing")
  $nugetPublishUrl = "https://www.myget.org/F/southside/"
}

task default -depends build

task build -Description "Build application.  Runs tests" -depends version, cleanBuildOutput, compile, test {
}

task test -Description "Runs tests" {
  if ($testAssemblies.Count -gt 0) {
    [string]$nunitVersion = Get-NunitVersion
    if ($inTeamCity) {
      Write-Host "Running Tests In TeamCity"
      [string] $nunit = "NUnit-" + $nunitVersion
      Write-Host "Running " $env:NUNIT_LAUNCHER v4.0 x64 $nunit $testAssemblies
      & $env:NUNIT_LAUNCHER v4.0 x64 $nunit $testAssemblies
    } else {
      Write-Host "Running Tests Outside TeamCity"
      [string] $nunitPath = Get-NunitPath
      & $nunitPath $testAssemblies /noshadow "/framework:net-4.0"
    }

    if ($LastExitCode -ne 0) { throw "Tests failed"}
  } else {
    Write-Host "No test assemblies..."
  }
}

Task compile -Description "Build application only" {
	exec {.nuget\nuget restore}
    exec { msbuild $sln_file /t:rebuild /m:4 /p:VisualStudioVersion=12.0 "/p:Configuration=$configuration" "/p:Platform=$platform" }
}

task pullCurrentAndBuild -Description "Does a git pull of the current branch followed by build" -depends pullCurrent, build

task pullCurrent -Description "Does a git pull" {
    git pull
}

task buildDist -Description "Update version. Build appication. Runs tests.  Builds Nuget packages" -depends build, createArtifacts {
}

task buildDistAndPublish -Description "Update version. Build appication. Runs tests. Builds Nuget packages. Deploys to MyGet." -depends buildDist, publish {

}

task cleanBuildOutput -Description "Cleans the BuildOutput folder" {
  if (Test-Path $buildOutputDir) {
    Remove-Item -Recurse -Force $buildOutputDir
  }
  New-Item -ItemType directory -Path $buildOutputDir
  New-Item -ItemType directory -Path $nugetOutputDir
}

task startRaven -Description "Starts RavenDB." {
  Start-Raven
}

Task version -Description "Version the assemblies" {
	Update-CommonAssemblyInfoFile $version $revision
}

Task versionReset -Description "Returns the version of the assemblies to 0.1.0.0" {
  Reset-CommonAssemblyInfoFile
}

Task createArtifacts -Description "Create artifacts" {
  $dllOutputsToPublish | % { Copy-DllOutputs $_ }
  $nugetPackagesToPublish | % {Create-NugetPackage $_ }
}

Task publish -Description "Publish NuGet Packages" {
  $nugetPackagesToPublish | % { Publish-ToMyGet $_ }
}

task ? -Description "Helper to display task info" {
  WriteDocumentation
}

function Update-CommonAssemblyInfoFile ([string] $version, [string]$revision) {
  if ($version -notmatch "[0-9]+(\.([0-9]+|\*)){1,3}") {
    Write-Error "Version number incorrect format: $version"
  }

  $versionPattern = 'AssemblyVersion\("[0-9]+(\.([0-9]+|\*)){1,2}"\)'
  $versionAssembly = 'AssemblyVersion("' + $version + '")';
  $versionFilePattern = 'AssemblyFileVersion\("[0-9]+(\.([0-9]+|\*)){1,3}"\)'
  $versionAssemblyFile = 'AssemblyFileVersion("' + $version + "." + $revision + '")';

  Get-ChildItem -filter .\Common\CommonAssemblyInfo.cs | % {
    $filename = $_.fullname

    if ($make_writable) { Writeable-File($filename) }

    $tmp = ($file + ".tmp")
    if (test-path ($tmp)) { remove-item $tmp }

    (get-content $filename) | % {$_ -replace $versionFilePattern, $versionAssemblyFile } | % {$_ -replace $versionPattern, $versionAssembly }  > $tmp
    write-host Updating file AssemblyInfo and AssemblyFileInfo: $filename --> $versionAssembly / $versionAssemblyFile

    if (test-path ($filename)) { remove-item $filename }
    move-item $tmp $filename -force

    if ($make_writable) { ReadOnly-File($filename) }

  }
}

function Version-Nuspec ([string]$project) {
  [string] $nuspecFilePath = Join-Path -Path ".\nuspec" -ChildPath ($project + ".nuspec") -Resolve
  Write-Host $nuspecFilePath
  [xml]$nuspecFile = Get-Content $nuspecFilePath
  $ns = New-Object System.Xml.XmlNamespaceManager($nuspecFile.NameTable)
  $ns.AddNamespace("ns", "http://schemas.microsoft.com/packaging/2010/07/nuspec.xsd")
  $versionNode = $nuspecFile.SelectSingleNode("//ns:version", $ns)
  if ($versionNode -eq $null) {
    throw "Cannot find version node in nuspec package for $nuspecFile"
  }
  $versionNode.innerText = $version + "." + $revision

  $nuspecFile.Save($nuspecFilePath)
}

function Copy-DllOutputs ([string] $projectName) {
  [string] $path = Join-Path (Join-Path "app/$projectName" "bin") $configuration
  [string] $destPath = Join-Path $buildOutputDir $projectName
  Copy-Item $path $destPath -recurse
}

function Publish-ToMyGet ([string] $package) {
  [string] $nugetFilePath = Join-Path -Path $nugetOutputDir -ChildPath ($package + "." + $version + "." + $revision + ".nupkg") -Resolve
  & .nuget\nuget push $nugetFilePath -s $nugetPublishUrl
}

function Create-NugetPackage ([string] $projectName) {
  Version-Nuspec $projectName
  [string] $source = Join-Path -Path "nuspec" -ChildPath ($projectName + ".nuspec")
  & .nuget\nuget pack $source -OutputDirectory $nugetOutputDir
  if ($LastExitCode -ne 0) { throw "Failed to create nuget package for $projectName"}
}

function Reset-CommonAssemblyInfoFile(){
  Update-CommonAssemblyInfoFile "0.1.0" "0"
}

function Writeable-File($filename){
	sp $filename IsReadOnly $false
}

function ReadOnly-File($filename){
	sp $filename IsReadOnly $true
}

function Start-Raven {
  $processActive = Get-Process Raven.Server -ErrorAction SilentlyContinue
  if (!$processActive)
  {
    #Find the correct version of RavenDB by looking at the referenced
    #package in the packages.config file of the solution
    [xml]$packages = Get-Content ".\.nuget\Packages.config"
    $server = $packages.SelectSingleNode("//package[@id='RavenDB.Server']")
    $version = $server.GetAttribute("version")
    [string] $path = ".\packages\RavenDB.Server.$version\tools\Raven.Server.exe"

	  #Start it up
    Write-Host "Starting Raven at: " $path
    if (test-path env:ConEmuDir) {
      & ConEmu -reuse -cmd "$path"
    } else {
      Start-Process -FilePath $path
    }
    Start-Sleep 5
    Exit 0
  }
  else
  {
    Write-Host "RavenDB already running"
    Exit 0
  }
}

function Get-NunitVersion {
  #Find the correct version of NUnit by looking at the referenced
  #package in the packages.config file of the solution
  [xml]$packages = Get-Content ".\.nuget\Packages.config"
  $server = $packages.SelectSingleNode("//package[@id='NUnit.Console']")
  $version = $server.GetAttribute("version")

  return $version
}
function Get-NunitPath {
  [string] $version = Get-NunitVersion
  [string] $path = ".\packages\Nunit.Runners.$version\tools\nunit-console.exe"

  return $path
}
