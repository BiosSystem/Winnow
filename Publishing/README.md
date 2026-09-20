# Publishing Winnow

Draft assets for publishing Winnow to winget and the PowerShell Gallery. Both
need credentials you hold, so nothing here publishes on its own. Read the notes
below before submitting.

## winget (`winget/`)

Three-file manifest for `BiosSystem.Winnow`, schema 1.12.0.

### winget needs an executable entry point (handled by the launcher)

winget's portable nested installer accepts only a `.exe` `RelativeFilePath`.
Verified locally: `.bat`, `.cmd`, and `.ps1` are all rejected
(`winget validate` reports "The file type of the referenced file is not
allowed"). Winnow is a PowerShell tree with no executable, so the release zip
needs a small `.exe` entry point.

That launcher is provided here as **source**, not a committed binary:

- `launcher/Winnow.cs` - a minimal C# launcher that finds `Winnow.ps1` next to
  itself and starts it with a UAC prompt, the same thing `Run.bat` does.
- `launcher/Build-Launcher.ps1` - compiles it with the C# compiler that ships in
  the .NET Framework (no toolchain to install, no prebuilt binary committed;
  `Winnow.exe` is `.gitignore`d).

To publish to winget:

1. Build the launcher and place `Winnow.exe` at the root of the release zip:
   ```powershell
   .\Publishing\launcher\Build-Launcher.ps1
   ```
   To do this in the release workflow, add a step before the "Create release
   ZIP" step and include `Winnow.exe` in that step's item list:
   ```yaml
   - name: Build winget launcher
     shell: pwsh
     run: .\Publishing\launcher\Build-Launcher.ps1 -OutputPath .\Winnow.exe
   ```
2. Set `PackageVersion` in all three manifest files to the release version.
3. Point `InstallerUrl` at that release's `Winnow-v<version>.zip` asset.
4. Replace the placeholder `InstallerSha256` with the hash of the **published**
   asset (the release workflow rebuilds on the runner, so hash the downloaded
   zip, not a local build):
   ```powershell
   (Get-FileHash .\Winnow-v<version>.zip -Algorithm SHA256).Hash
   ```
5. Validate and test locally:
   ```powershell
   winget validate --manifest .\Publishing\winget
   winget install --manifest .\Publishing\winget   # in a throwaway VM/Sandbox
   ```
6. Submit with [wingetcreate](https://github.com/microsoft/winget-create) or a
   PR to `microsoft/winget-pkgs`.

Alternative: skip winget and publish to the PowerShell Gallery only (below,
validated cleanly) plus the existing direct download. That path needs no
launcher and is lower friction for a script tool.

Secondary note: the `neutral` architecture reflects the architecture-independent
PowerShell payload. If submission validation rejects it, change it to `x64`.

## PowerShell Gallery (`PowerShellGallery/`)

`Publish-Winnow.ps1` builds the self-contained standalone, injects a
`PSScriptInfo` block with the fixed script GUID, validates it with
`Test-ScriptFileInfo`, and publishes with `Publish-Script` only when you pass
`-ApiKey`. The modular `Winnow.ps1` cannot be a gallery script because it
dot-sources the repository tree; the standalone embeds everything, so it is what
gets published.

Dry run (build and validate, no publish, no key needed):
```powershell
.\Publishing\PowerShellGallery\Publish-Winnow.ps1
```

Publish (uses your key; the script never stores it):
```powershell
.\Publishing\PowerShellGallery\Publish-Winnow.ps1 -ApiKey <your PowerShell Gallery key>
```

Installed by users with:
```powershell
Install-Script -Name Winnow
```

Fixed script GUID: `0e5a6893-36f8-46da-b8b8-0d9500d7a492`. Do not regenerate it;
the gallery keys the script by this GUID across versions.

## What still needs you

- A decision on winget: include the launcher (source and build step are
  provided here) so the release zip carries `Winnow.exe`, or ship PowerShell
  Gallery only.
- winget and PowerShell Gallery accounts and credentials.
- The published release asset hash (winget).
- A throwaway VM or Windows Sandbox to test the winget install end to end before
  submitting.
