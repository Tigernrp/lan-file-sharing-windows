# Code Signing Policy

Free code signing provided by SignPath.io, certificate by SignPath Foundation.

## Scope

Official signed releases are built only from a public revision of this repository by a GitHub-hosted Windows runner. Project-owned executable and PowerShell files are signed. The payload is signed before it is embedded, and the final installer is signed in a separate second stage.

No signing credential, private key, setup key, or API token is committed to the repository. Workflow credentials are stored only as restricted GitHub Actions secrets and SignPath project configuration.

## Controls

- The **author** prepares the source revision and release notes.
- The **reviewer** confirms the source diff, tests, privacy boundary, dependency notices, file inventory, and expected version.
- The signing **approver** authorizes the SignPath request only for the reviewed public revision and expected artifact.
- The project owner initially fills all three roles; they can be separated when more maintainers join.
- Every repository and SignPath account with release duties must use multi-factor authentication (MFA).
- Signing is restricted to approved version tags or the protected release branch.
- The pipeline stops if tests, provenance, metadata, signatures, timestamps, signer identity, inventory, embedded payload, or checksum verification fails.

## Automated release behavior

The release workflow gives each SignPath request a bounded 30-minute timeout and fails closed if signing is rejected, unavailable, cancelled, or incomplete. A cancellation or timeout cannot reach the publish job. The workflow may retain a short-lived private diagnostic artifact for maintainers, but it does not attach unsigned or partially signed files to a public release.

A Draft Release is created only after the signed payload is embedded, the final installer is separately signed, and the final release gate validates the signer, timestamps, product metadata, embedded inventory, and hashes. Publishing the draft remains a deliberate maintainer action.

## Unsigned legacy release

Version 3.81 is an unsigned legacy artifact published only to document the previously released application and support the SignPath Foundation application. It is not represented as Smart App Control-compatible. Users must not be told to disable Windows security controls.

## Incident response

If signing credentials, workflow trust, or a release artifact may be compromised, publication stops. The affected artifact is withdrawn, the incident is reported privately, credentials are rotated or revoked, and a replacement is built from a reviewed clean revision.
