# Guardian Agent Integration

This workspace is monitored by Guardian. Files under `.guardian/` are generated and owned by Guardian.

## Read
- `.guardian/critiques.json` - machine-readable snapshot of active critiques
- `.guardian/agent_queue.jsonl` - append-only event stream (use `tail -f`)
- `.guardian/chat.md` - optional human-to-Guardian notes
- `.guardian-proposals/fix_proposals.jsonl` - optional fix proposal queue (append-only JSONL)

## Rules
1. Prioritize: critical > warning > info
2. Make minimal, safe changes (avoid large refactors unless requested)
3. Run tests after changes

## Forbidden
- Do not edit any `.guardian/*` files
- Do not read or exfiltrate secrets (`.env`, keys, credentials)
- Do not auto-commit or auto-push

## Fix Proposals
- If you want Guardian to review a fix, append a proposal to `.guardian-proposals/fix_proposals.jsonl`.
- Proposals MUST include `proposal_id`, `timestamp`, `file_path`, and `proposed_content` (FULL updated file content).
