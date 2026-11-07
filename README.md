# Praisenter NDI Runtime Libraries

Binary-only Maven packaging of supplied NDI&reg; 6.3.2.0 runtime libraries.
No Java binding, JNI library, executable tools, or SDK headers are included.
Inputs are committed under [natives](natives); packaging never downloads or
installs an SDK. NDI&reg; is a registered trademark of Vizrt NDI AB.
Vendor information and SDK terms: [ndi.video](https://ndi.video/).

## Artifacts

Coordinates: `org.praisenter:ndi:6.3.2.0-1`, type `zip`.

| Classifier | Intended platform | Library |
| --- | --- | --- |
| `windows-x86_64` | Windows x64 | `Processing.NDI.Lib.x64.dll` |
| `linux-x86_64` | Linux x64 | `libndi.so` |
| `macos-x86_64` | macOS Intel | `libndi.dylib` |
| `macos-aarch64` | macOS ARM64 | `libndi.dylib` |

Each ZIP has this layout, without an enclosing directory:

```text
lib/<original-library-name>
licenses/<original-vendor-notice-name>
licenses/UPSTREAM-NOTICE.txt
build-info.properties
```

The Windows vendor notice is `Processing.NDI.Lib.Licenses.txt`; the Unix notice
is `libndi_licenses.txt`. Both remain byte-for-byte identical to their supplied
originals.

The POM owns four attached classifier ZIPs; there is no unclassified JAR.
Maven does not select a classifier from the host OS/CPU. Select `type=zip` and
the classifier explicitly, using consumer profiles or a CI matrix as needed.

```xml
<dependency>
    <groupId>org.praisenter</groupId>
    <artifactId>ndi</artifactId>
    <version>6.3.2.0-1</version>
    <type>zip</type>
    <classifier>windows-x86_64</classifier>
</dependency>
```

Use Maven Dependency Plugin to resolve and unpack the selected ZIP before
application packaging. The [consumer fixture](src/it/consumer/pom.xml) provides
a complete `artifactItems` example. Include the entire extracted directory,
including license notices, in the application distribution.

These are C ABI runtime libraries, not JNI implementations. Use your existing
NDI binding or foreign-function interface to load the library from its absolute
application-local path. Merely placing the ZIP on the classpath/module path or
calling `System.load` does not supply a Java binding. Do not install the runtime
into system-wide directories. The consumer owns OS dependencies, library search
paths, any required SONAME aliases, ABI compatibility, macOS application signing
and notarization. This project does not rewrite install names or create aliases.

## Local Build

Packaging and validation support Windows PowerShell 5.1 and PowerShell 7.
Maven consumption uses Maven 3.9+ (not Maven 4); CI uses Java 25.
Packaging needs only PowerShell/.NET and the checked-in files, with no network
access. Maven may download its own plugins on the first build.

```powershell
./.github/scripts/package.ps1
./.github/scripts/test.ps1 -Classifier windows-x86_64 -ArchiveOnly
mvn -B -ntp install
mvn -B -ntp -f src/it/consumer/pom.xml clean verify '-Dndi.classifier=windows-x86_64' '-Dndi.artifact.version=6.3.2.0-1'
./.github/scripts/test.ps1 -Classifier windows-x86_64
```

Do not run root `mvn clean` after packaging: it removes the prepared ZIPs.
The consumer's `clean` is safe because it removes only its own output.
Scripts locate project files relative to themselves, not the working directory.
Stop on a failing command; do not proceed to install or publish incomplete output.

There are two scripts: `package.ps1` validates supplied inputs and builds the
ZIPs; `test.ps1` verifies archives and, unless `-ArchiveOnly` is supplied, the
Maven-unpacked files. Verification loads the packaging helpers without rebuilding.
Run archive checks for every classifier with:

```powershell
foreach ($classifier in @('windows-x86_64', 'linux-x86_64', 'macos-x86_64', 'macos-aarch64')) {
   ./.github/scripts/test.ps1 -Classifier $classifier -ArchiveOnly
}
```

Archive checks enforce the exact layout, nonempty files, locked hashes,
version/classifier metadata, original notices and regular-file permissions.
ZIP timestamps come from `project.build.outputTimestamp`; compression bytes may
differ across .NET versions even though input bytes and timestamps are fixed.

## Updating Supplied Inputs

[natives.properties](natives.properties) locks the SDK version, explicit paths,
and SHA-256 hashes of every library and original notice. Extra files under
`natives` fail validation. Empty files, symlinks/reparse points in input paths,
path traversal, and checksum mismatches also fail. The scripts never silently
substitute different files or versions.

1. Obtain and review the exact SDK release and its distribution terms manually.
2. Replace the four approved runtime files and their original vendor notices.
   Confirm the intended OS/CPU architectures and whether additional dependencies
   or aliases are necessary; folder names alone are not evidence.
3. Calculate hashes using `Get-FileHash -Algorithm SHA256`, then update the input
   lock after reviewing the changes. Do not normalize vendor notice line endings.
4. Update the POM and fixture versions and provenance notice. Artifact versions
   use `<SDK-version>-<packaging-revision>`, for example `6.3.2.0-1`.
5. Run packaging, archive checks, Maven installation and consumer verification.

The [Git attributes](.gitattributes) preserve all supplied files under `natives`
without text conversion. Current libraries are below GitHub's per-file size limit
and do not require Git LFS. Keep verified original SDK downloads in durable storage.

## CI And Release

[Verification](.github/workflows/verify.yml) packages and validates all ZIPs on
Ubuntu. Windows x64, Linux x64,
macOS Intel and macOS ARM64 jobs download those artifacts, install their selected
classifier, and verify actual Maven resolution and unpacked bytes. No native
library loading, sender/receiver, or network discovery tests run. These checks
do not prove binary architectures, OS baselines, or runtime compatibility.
Pull-request verification needs no publishing secrets.

[Release](.github/workflows/release.yml) is manually dispatched using an existing
reviewed tag such as `v6.3.2.0-1`. It rejects snapshots and mismatched tags, locks
the tag to a commit, and runs full verification at that commit. After verification,
the publish job downloads and checks the exact tested ZIPs before signing and
uploading them. It does not rebuild or run root `clean`.

The `release` profile signs attached artifacts and uploads them for Central
validation. Automatic publication is disabled; manually promote the validated
deployment in the Central Portal. Ordinary local builds neither sign nor publish.
Repository metadata currently targets `praisenter/ndi-natives-maven`; update the
POM URL/SCM if the eventual GitHub repository has a different name.

## Licensing

The native libraries are proprietary vendor binaries, not MIT/GPL-licensed
because their notices include permissively licensed third-party components.
The supplied notices require inclusion with binary distributions and reference
the [NDI SDK agreement](https://ndi.link/ndisdk_license). The maintained provenance
notice is not a substitute for that agreement or the original notices.

Consumers must comply with the applicable SDK/EULA requirements, third-party
terms, and NDI trademark/link attribution in their application and documentation.
Review the SDK's [licensing guidance](https://docs.ndi.video/all/developing-with-ndi/sdk/licensing)
and [distribution guidance](https://docs.ndi.video/all/developing-with-ndi/sdk/software-distribution).