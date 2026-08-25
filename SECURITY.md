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
- Verified: ZeroLose stores API keys in the macOS Keychain (via `Secrets.swift`); no
  hardcoded keys are present in the source tree or the packaged binary.
- Generated runtime artifacts (Xcode `DerivedData`, build logs, CCM vector caches,
  `ZeroLose/dist`) are git-ignored and must never be committed.
- Run `python3 scripts/verify_all.py` before declaring any provider/config change
  complete; it validates provider config, git-ignore coverage, symlink contract,
  and real secret presence.
