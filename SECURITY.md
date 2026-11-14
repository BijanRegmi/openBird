# Security policy

openBird delivers code to devices, so security reports are taken seriously.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability
reporting ("Report a vulnerability" on the repository's Security tab).
Include steps to reproduce and the affected version or commit.

## What's in scope

* Signing: anything that lets a patch reach devices without a valid
  signature from the organization's managed key (or the customer's key).
* Authentication and authorization of the API and the console (API keys,
  sessions, roles, the console's CSRF header).
* Signed upload and download URLs.
* Exposure of `MASTER_KEY`-protected material (managed signing keys).

## Operator notes

* Keep `MASTER_KEY` secret and backed up. It encrypts the managed signing
  keys; losing it means releases in the field can't verify new patches.
* Serve openBird over HTTPS. `base_url` is built into every release.
