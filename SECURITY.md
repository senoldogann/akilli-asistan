# Security Policy

## Supported version

Security fixes target the latest code on `main`.

## Reporting a vulnerability

Do not publish sensitive vulnerability details in a public issue before the maintainer has had an opportunity to triage them.

A useful report includes:

- a concise description of the vulnerability;
- reliable reproduction steps;
- affected component and version/commit;
- impact assessment;
- suggested mitigation, if known.

## Security model

Akıllı Asistan treats model/provider output as untrusted input.

The computer-use runtime therefore keeps deterministic authority outside the model:

- `ActionPolicy` validates whether proposed actions are executable;
- stale observation/state versions are rejected;
- Chrome focus/window continuity is checked before live input;
- protected navigation remains fail-closed until runtime verification allows it;
- unknown native Computer Use actions fail closed;
- retries and waits are bounded;
- emergency-stop checks remain active during long-running native input;
- semantic outcome verification, not model self-report, determines success.

## Secrets and private data

- Never commit API keys, credentials, private keys, access tokens, or session secrets.
- Use environment variables or platform secret storage as appropriate for the executable.
- Working-memory telemetry must not retain raw screenshots, API headers, provider payloads, or private typed content.
- Generated build/runtime artifacts must remain ignored by Git.

## Automation scope

The project is intended for user-authorized interaction and testing. Security-sensitive boundaries must not be weakened to add stealth/evasion, anti-proctoring, monitoring defeat, CAPTCHA bypass, or access-control circumvention behavior.

## Verification

Run the repository gate before declaring a security-sensitive change complete:

```bash
python3 scripts/verify_all.py
```
