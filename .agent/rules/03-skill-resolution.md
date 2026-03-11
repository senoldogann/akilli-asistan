# 03 - SKILL RESOLUTION PROTOCOL

> **Principle:** "If the capability is missing, acquire the capability before pretending it exists."

## 1. WHEN TO TRIGGER
Use the skill resolution flow when:
- A required capability is not present in local shared skills.
- A named skill is missing.
- The task clearly needs a specialized workflow the current skill inventory does not cover.

## 2. RESOLUTION ORDER
1. Search local shared skills in `.agent/skills/`.
2. Search user-level Codex skills in `$CODEX_HOME/skills`.
3. If still missing, run `scripts/skill.sh ensure "<query-or-skill-name>"`.
4. If multiple remote candidates remain, present the options instead of installing arbitrarily.

## 3. INSTALLATION RULES
- Prefer exact-name curated or official skills when available.
- Prefer trusted publishers when multiple remote skills claim the same capability.
- Prefer repo-shared installation when the capability should serve Antigravity, Claude Code, and OpenCode together.
- Use global Codex install when the remote ecosystem only exposes a Codex-native package format.
- Accept direct `skills.sh` page URLs as install targets when the user points to a specific skill page.
- After repo-local installation, regenerate the index with `python3 scripts/generate_skill_index.py`.

## 4. FAIL-SAFE
- Do not hallucinate a missing skill.
- Do not claim a skill is installed before confirming the destination exists.
- If installation requires network access or manual choice, say so explicitly.
