# Security Policy

## Supported Versions

Security fixes are applied to the latest version on `main`.

## Reporting a Vulnerability

If you discover a security issue, do not open a public issue first.

Send a report to the maintainer with:
- A clear description of the issue
- Reproduction steps
- Impact assessment
- Suggested mitigation (if available)

You will receive an acknowledgment as soon as possible. Valid reports will be
triaged and fixed before public disclosure when feasible.

## Scope Notes

- Never commit API keys or credentials.
- Assume model output is untrusted input.
- Prefer allowlist-based command execution over free-form shell execution.
