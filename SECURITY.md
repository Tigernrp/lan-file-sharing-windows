# Security Policy

## Supported releases

Security fixes target the latest published release and the default branch. The unsigned 3.81 legacy installer is preserved for project history and must not be treated as a trusted-publisher release.

## Private vulnerability reporting

Use GitHub private vulnerability reporting from the repository **Security** tab and select **Report a vulnerability**. This is the primary private route for suspected vulnerabilities, accidental secret disclosure, or a flaw that could expose Windows credentials, SMB data, local accounts, firewall configuration, or signing infrastructure.

Do not post credentials, passwords, NetBird setup keys, access tokens, private logs, personal data, or exploit details in public issues. Public issues are appropriate only for non-sensitive defects and feature requests.

Include the affected version, Windows version, reproducible steps, impact, and a minimal redacted diagnostic description. The maintainers will acknowledge the report, assess it, and coordinate a fix and disclosure when appropriate.

## Release integrity

Official signed releases must pass repository validation, tests, file-inventory checks, Authenticode verification, timestamp verification, embedded-payload verification, and checksum generation. Signing credentials are never committed to this repository.
