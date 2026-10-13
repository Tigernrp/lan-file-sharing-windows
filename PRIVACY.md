# Privacy

LAN File Sharing has no telemetry. The application does not send usage analytics, file names, file contents, Windows credentials, or share configuration to the project maintainers.

## Local sharing

Local mode uses Windows SMB between computers selected by the user. Windows processes authentication and file access. The application stores its configuration locally. Protected Password credentials are stored using Windows-protected facilities and are not sent to the project maintainers.

## Online mode and NetBird

Online mode is optional. The application contacts external services only after an explicit user action related to NetBird installation, sign-in, connection, peer discovery, or status retrieval.

- The install action downloads the official NetBird Windows installer and verifies the publisher before installation.
- Sign-in and connection actions communicate with NetBird services under the user's NetBird account and network configuration.
- Status retrieval reads connection and peer information needed to show the Online page and apply selected peer restrictions.
- SMB file transfer is handled by Windows over the network path. LAN File Sharing does not relay file contents through a project-operated server.

NetBird is an independent project and service. Its collection and processing are governed by the NetBird terms and privacy information published by NetBird.

## Local data and removal

The application stores share state, recovery records, startup preferences, and encrypted remembered connection data on the Windows computer. Uninstall removes application-owned configuration when cleanup is safe. The user's original shared files are not deleted. A separately installed NetBird client and the user's NetBird account are not removed automatically.
