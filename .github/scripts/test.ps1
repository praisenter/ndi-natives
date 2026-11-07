param(
    [Parameter(Mandatory)]
    [ValidateSet('windows-x86_64', 'linux-x86_64', 'macos-x86_64', 'macos-aarch64')]
    [string] $Classifier,
    [switch] $ArchiveOnly,
    [string] $DistributionDirectory,
    [string] $ConsumerDirectory
)

. "$PSScriptRoot/package.ps1"

function Get-StreamHash([System.IO.Stream] $Stream) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

$configuration = Get-NativeConfiguration
$platform = @($configuration.Platforms | Where-Object { $_.Classifier -eq $Classifier })[0]
if (!$DistributionDirectory) { $DistributionDirectory = "$root/target/distributions" }
$name = "ndi-$($configuration.Version)-$Classifier.zip"
$lines = @(Get-Content -LiteralPath "$DistributionDirectory/SHA256SUMS" | Where-Object { $_.EndsWith("  $name") })
if ($lines.Count -ne 1 -or $lines[0] -cnotmatch ('^[0-9a-f]{64}  ' + [regex]::Escape($name) + '$') -or
    (Get-FileHash -LiteralPath "$DistributionDirectory/$name" -Algorithm SHA256).Hash -ne $lines[0].Substring(0, 64)) {
    throw "Archive checksum missing or incorrect: $name"
}
$expectedHashes = @{
    "lib/$($platform.Library.Name)" = $platform.Library.Hash
    "licenses/$($platform.Notice.Name)" = $platform.Notice.Hash
    'licenses/UPSTREAM-NOTICE.txt' = (Get-FileHash -LiteralPath $configuration.Provenance -Algorithm SHA256).Hash.ToLowerInvariant()
}
$expected = @($expectedHashes.Keys) + @('build-info.properties')
$metadata = Get-BuildMetadata $configuration $platform
$zip = [System.IO.Compression.ZipFile]::OpenRead("$DistributionDirectory/$name")
try {
    if ($zip.Entries.Count -ne $expected.Count -or (Compare-Object @($zip.Entries.FullName) $expected -CaseSensitive)) {
        throw "Unexpected, missing or duplicate ZIP entries: $name"
    }
    foreach ($entry in $zip.Entries) {
        if ($entry.Length -eq 0 -or (($entry.ExternalAttributes -shr 16) -band 65535) -ne 33188 -or
            $entry.LastWriteTime.DateTime -ne $configuration.Timestamp.UtcDateTime) {
            throw "Empty entry, incorrect permissions or timestamp: $($entry.FullName)"
        }
        if ($expectedHashes.ContainsKey($entry.FullName)) {
            $stream = $entry.Open()
            try { $hash = Get-StreamHash $stream } finally { $stream.Dispose() }
            if ($hash -ne $expectedHashes[$entry.FullName]) { throw "Entry checksum mismatch: $($entry.FullName)" }
        }
    }
    $reader = [System.IO.StreamReader]::new($zip.GetEntry('build-info.properties').Open())
    try { $actualMetadata = $reader.ReadToEnd() | ConvertFrom-StringData } finally { $reader.Dispose() }
    if ($actualMetadata.Count -ne $metadata.Count) { throw 'Unexpected build metadata properties' }
    foreach ($key in $metadata.Keys) {
        if ($actualMetadata[$key] -cne $metadata[$key]) { throw "Incorrect build metadata: $key" }
    }
    if (!$ArchiveOnly) {
        if (!$ConsumerDirectory) { $ConsumerDirectory = "$root/src/it/consumer/target/native libraries" }
        $directory = (Resolve-Path -LiteralPath $ConsumerDirectory).Path
        $actualFiles = @(Get-ChildItem -LiteralPath $directory -File -Recurse -Force |
            ForEach-Object { $_.FullName.Substring($directory.Length + 1).Replace('\', '/') })
        if ($actualFiles.Count -ne $expected.Count -or (Compare-Object $actualFiles $expected -CaseSensitive)) {
            throw 'Unexpected Maven-unpacked layout'
        }
        foreach ($entry in $zip.Entries) {
            $stream = $entry.Open()
            try { $hash = Get-StreamHash $stream } finally { $stream.Dispose() }
            if ((Get-FileHash -LiteralPath (Join-Path $directory $entry.FullName) -Algorithm SHA256).Hash -ne $hash) {
                throw "Maven unpacking changed bytes: $($entry.FullName)"
            }
        }
        Write-Host "Verified Maven unpacking: $Classifier"
    }
} finally { $zip.Dispose() }
Write-Host "Verified $name"