param([switch] $CheckRelease)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$classifiers = @('windows-x86_64', 'linux-x86_64', 'macos-x86_64', 'macos-aarch64')

function Resolve-InputFile([string] $InputRoot, [string] $Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -notmatch '^[A-Za-z0-9_./-]+$' -or
        [System.IO.Path]::IsPathRooted($Relative) -or ($Relative -split '/' -contains '..') -or
        ($Relative -split '/' -contains '.') -or $Relative.StartsWith('/') -or $Relative.Contains('//')) {
        throw "Invalid relative input path: $Relative"
    }
    $current = $InputRoot
    foreach ($part in ($Relative -split '/')) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Symlink/reparse input is not supported: $Relative"
        }
    }
    if ($item.PSIsContainer -or $item.Length -eq 0) { throw "Missing or empty input: $Relative" }
    return $item.FullName
}

function Get-NativeConfiguration([string] $InputRoot = $root) {
    [xml] $pom = Get-Content -LiteralPath "$InputRoot/pom.xml" -Raw
    $lock = Get-Content -LiteralPath "$InputRoot/natives.properties" -Raw | ConvertFrom-StringData
    $version = [string] $pom.project.version
    if ($lock['ndi.version'] -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        $version -notmatch ('^' + [regex]::Escape($lock['ndi.version']) + '-[1-9]\d*(-SNAPSHOT)?$')) {
        throw 'POM version must be the locked NDI version plus a packaging revision'
    }
    if ($lock.Count -ne (1 + $classifiers.Count * 4)) { throw 'Unexpected input lock properties' }
    $timestamp = [DateTimeOffset]::Parse([string] $pom.project.properties.'project.build.outputTimestamp',
        [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    if ($timestamp.Year -lt 1980 -or $timestamp.Year -gt 2107 -or $timestamp.Second % 2 -ne 0) {
        throw 'ZIP timestamp must be within 1980-2107 and have even seconds'
    }
    $platforms = @()
    $allowed = @()
    foreach ($classifier in $classifiers) {
        $files = @{}
        foreach ($kind in @('library', 'notice')) {
            $relative = $lock["$classifier.$kind"]
            if (!$relative -or !$relative.StartsWith('natives/')) { throw "Input must be under natives/: $classifier.$kind" }
            $path = Resolve-InputFile $InputRoot $relative
            $hash = $lock["$classifier.$kind.sha256"]
            if ($hash -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hash) {
                throw "Missing or incorrect locked SHA-256: $classifier.$kind"
            }
            $files[$kind] = @{ Path = $path; Relative = $relative; Hash = $hash; Name = [System.IO.Path]::GetFileName($path) }
            $allowed += $path
        }
        $expectedLibrary = if ($classifier.StartsWith('windows-')) { 'Processing.NDI.Lib.x64.dll' }
            elseif ($classifier.StartsWith('linux-')) { 'libndi.so' } else { 'libndi.dylib' }
        if ($files.library.Name -cne $expectedLibrary -or $files.notice.Name -notmatch '^[A-Za-z0-9_.-]+\.txt$' -or
            $files.notice.Name -eq 'UPSTREAM-NOTICE.txt') { throw "Unexpected library/notice name: $classifier" }
        $platforms += @{ Classifier = $classifier; Library = $files.library; Notice = $files.notice }
    }
    $actual = @(Get-ChildItem -LiteralPath "$InputRoot/natives" -File -Recurse -Force | ForEach-Object { $_.FullName })
    if ($actual.Count -ne $allowed.Count -or (Compare-Object $actual $allowed)) { throw 'Unexpected or duplicate native input files' }
    $provenance = Resolve-InputFile $InputRoot 'licenses/UPSTREAM-NOTICE.txt'
    return @{ Version = $version; NdiVersion = $lock['ndi.version']; Timestamp = $timestamp; Platforms = $platforms; Provenance = $provenance }
}

function Get-BuildMetadata($Configuration, $Platform) {
    return @{
        'artifact.version' = $Configuration.Version
        'ndi.version' = $Configuration.NdiVersion
        'classifier' = $Platform.Classifier
        'library.source' = $Platform.Library.Relative
        'library.sha256' = $Platform.Library.Hash
        'notice.source' = $Platform.Notice.Relative
        'notice.sha256' = $Platform.Notice.Hash
        'provenance.sha256' = (Get-FileHash -LiteralPath $Configuration.Provenance -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Write-Utf8File([string] $Path, [string] $Text) {
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

if ($MyInvocation.InvocationName -eq '.') { return }

$configuration = Get-NativeConfiguration
if ($CheckRelease) {
    if ($configuration.Version.EndsWith('-SNAPSHOT')) { throw 'Cannot release a snapshot' }
    Write-Host "Release inputs verified: $($configuration.Version)"
    return
}
$output = "$root/target/distributions"
$work = "$root/target/packaging"
foreach ($directory in @($output, $work)) {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$checksums = @()
foreach ($platform in $configuration.Platforms) {
    $classifier = $platform.Classifier
    $staging = "$work/$classifier"
    New-Item -ItemType Directory -Path "$staging/lib", "$staging/licenses" -Force | Out-Null
    Copy-Item -LiteralPath $platform.Library.Path -Destination "$staging/lib/$($platform.Library.Name)"
    Copy-Item -LiteralPath $platform.Notice.Path -Destination "$staging/licenses/$($platform.Notice.Name)"
    Copy-Item -LiteralPath $configuration.Provenance -Destination "$staging/licenses/UPSTREAM-NOTICE.txt"
    $metadata = Get-BuildMetadata $configuration $platform
    $lines = @($metadata.Keys | Sort-Object | ForEach-Object { "$_=$($metadata[$_])" })
    Write-Utf8File "$staging/build-info.properties" (($lines -join "`n") + "`n")
    $name = "ndi-$($configuration.Version)-$classifier.zip"
    $zip = [System.IO.Compression.ZipFile]::Open("$output/$name", [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $staging -File -Recurse | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $configuration.Timestamp
            $entry.ExternalAttributes = -2119958528
            $sourceStream = $file.OpenRead()
            $entryStream = $entry.Open()
            try { $sourceStream.CopyTo($entryStream) }
            finally { $entryStream.Dispose(); $sourceStream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath "$output/$name" -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums += "$hash  $name"
    Write-Host "Packaged $name"
}
Write-Utf8File "$output/SHA256SUMS" (($checksums -join "`n") + "`n")