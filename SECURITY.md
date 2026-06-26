# Security Policy

## Supported versions

Security fixes target the latest released version and `main`. If you use
legion-core as a vendored engine, update to the latest release before reporting
issues against old code unless the vulnerability is still reproducible on
`main`.

## Reporting a vulnerability

Please do not open public issues for suspected vulnerabilities, leaked secrets,
sandbox escapes, credential handling bugs, or command-injection paths.

Use GitHub private vulnerability reporting for this repository when available.
If that is unavailable, contact the maintainers through the Opus Aether GitHub
organization with:

- affected version or commit
- affected command, plugin, or script
- reproduction steps
- expected impact
- any logs or artifacts, with secrets redacted

We will acknowledge credible reports within 7 days, keep the report private
while a fix is prepared, and publish remediation notes once a safe release is
available.
