# Publishing Winnow

Draft assets for publishing Winnow to winget and the PowerShell Gallery. Both
need credentials you hold, so nothing here publishes on its own. Read the notes
below before submitting.

## winget (`winget/`)

Three-file manifest for `BiosSystem.Winnow`, schema 1.12.0.

### Blocker: winget needs an executable entry point

winget's portable nested installer accepts only a `.exe` `RelativeFilePath`.
This was verified locally:

```
> winget validate --manifest .\Publishing\winget
Manifest Error: The file type of the referenced file is not allowed.
[RelativeFilePath] Value: Run.bat
```

`.bat`, `.cmd`, and `.ps1` are all rejected. Winnow ships no executable, so it
cannot be published to winget as it stands. Two options:

- **(a) Add a launcher `Winnow.exe` to the release zip.** A ~10-line stub (C#
  `csc`, or PS2EXE over `Run.bat`/`Winnow.ps1`) that starts `Winnow.ps1` from
  its own folder. The manifest here is already written for this: its
  `RelativeFilePath` is `Winnow.exe`. Adding a compiled binary to a repo whose
  ethos is open-source transparency is a call worth making deliberately (ship
  the launcher's source and build step alongside it).
- **(b) Skip winget, publish to the PowerShell Gallery only** (below), which
  validated cleanly, plus the existing direct download. This is the lower-friction
  path for a script tool and needs no binary.

If you take option (a), then submit:

1. Build `Winnow.exe` and include it in the release zip.
2. Set `PackageVersion` in all three files to the release version.
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

- A decision on the winget blocker: add a `Winnow.exe` launcher (option a) or
  ship PowerShell Gallery only (option b).
- winget and PowerShell Gallery accounts and credentials.
- The published release asset hash (winget).
- A throwaway VM or Windows Sandbox to test the winget install end to end before
  submitting.
