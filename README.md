# LAN File Sharing for Windows

LAN File Sharing is a Windows desktop application for sharing a drive, folder, or file through Windows SMB. It supports read-only or modify access, Windows current-account access, a dedicated protected local account, remembered client mappings, and optional private connectivity between locations through NetBird.

**Current source version: 3.81**

This repository contains the public source for the Windows x64 application. Release 3.81 is the existing unsigned legacy release used to establish the public project. It may be blocked by Windows Smart App Control because it has no trusted publisher signature. Do not disable Windows security controls to install it. A future release will be published as signed only after SignPath Foundation accepts the project and the signed build passes the release checks in this repository.

## What the application changes

Installation and host-sharing actions require Windows administrator approval. Depending on the selected features, the application can:

- install files under the Windows program location and add Start menu or startup entries;
- create and manage a dedicated local account for Protected Password sharing;
- create SMB shares and apply the selected share and NTFS permissions;
- add narrowly scoped Windows Firewall rules for SMB access;
- remember encrypted Windows credentials and mapped-drive choices for the signed-in user;
- download and silently install the official NetBird Windows client after an explicit user action; and
- restrict Online SMB firewall access to selected NetBird peer addresses.

The application does not disable Smart App Control, Microsoft Defender, or other Windows security controls.

## Install and run

1. Download an installer from the repository's Releases page.
2. Verify its SHA-256 checksum and Authenticode status before running it.
3. Start the installer and approve the Windows administrator prompt.
4. Open **LAN File Sharing**, choose the data to share, an access mode, and a permission level.
5. Use the **Online** page only when the computers are in different locations. Each computer must join the same authorized NetBird network.

For source builds, use Windows PowerShell 5.1 on Windows 10 or Windows 11 x64:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Check-Encoding.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PublicRepository.ps1 -Version 3.81
```

## Remove the application

Use **Settings > Apps > Installed apps > LAN File Sharing > Uninstall**, or run the project's uninstall entry point as administrator. Removal stops application-managed shares and startup tasks, removes application-owned firewall rules and protected accounts when safe, deletes installed program files, and keeps the user's original shared data. If cleanup cannot be completed safely, recovery state is retained and reported instead of silently deleting unrelated Windows configuration.

Removing LAN File Sharing does not remove a separately installed NetBird client or delete the user's NetBird account. NetBird can be removed from Windows Installed apps when it is no longer needed.

## Online behavior and privacy

LAN File Sharing has no telemetry. Local SMB sharing does not require a cloud service. Online mode uses NetBird only after an explicit user action to install, sign in, connect, or retrieve status. See [Privacy](PRIVACY.md) for the data and network boundaries.

## Security

Never post passwords, setup keys, access tokens, private logs, or personal network details in a public issue. Use the private route in [Security](SECURITY.md) for a vulnerability or accidental secret disclosure.

## Code signing policy

Release builds are designed to be built from a public GitHub revision, reviewed, signed in two stages, and verified before publication. See the [Code signing policy](CODE_SIGNING_POLICY.md).

Free code signing provided by SignPath.io, certificate by SignPath Foundation.

### Verify a downloaded release

Run these commands in Windows PowerShell, replacing the file name with the downloaded release:

```powershell
$installer = '.\LanFileSharing-Setup-v3.82.exe'
Get-FileHash -Algorithm SHA256 -LiteralPath $installer
Get-AuthenticodeSignature -LiteralPath $installer | Format-List Status,StatusMessage,SignerCertificate,TimeStamperCertificate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ReleaseArtifact.ps1 -InstallerPath $installer -Version 3.82 -SignerPattern '^CN=SignPath Foundation' -RequireTimestamp -OutputPath .\release-verification.json
```

Compare the SHA-256 value with the checksum attached to the GitHub Release. A valid signed release must report `Status: Valid`, the expected SignPath Foundation publisher, a timestamp certificate, matching version metadata, and valid signatures for every project-owned executable and PowerShell file in the payload.

## Project documents

- [MIT License](LICENSE)
- [Privacy](PRIVACY.md)
- [Security](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Code signing policy](CODE_SIGNING_POLICY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Thai quick start](QUICKSTART-TH.md)
- [Online setup guide](docs/ONLINE-TH.md)

## License

LAN File Sharing is released under the [MIT License](LICENSE). Copyright (c) 2026 LAN File Sharing contributors.
