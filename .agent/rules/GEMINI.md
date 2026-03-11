# GEMINI: Antigravity Rule Entry
> Version 2.2

This file is the Antigravity-native constitutional entry point for the Maestro rule system. Other supported providers consume the same policy through their own documented adapters; unsupported providers are intentionally not maintained in this repository.

## Rule Modules
1. `00-ARCHITECT-MANIFESTO.md` - Philosophic core
2. `01-safety-and-persistence.md` - Memory and safety
3. `02-research-and-anti-loop.md` - Current-information escalation and loop prevention
4. `03-skill-resolution.md` - Missing-skill acquisition and installation
5. `05-self-reflection.md` - Metacognition and correction
6. `10-parallel-execution.md` - Efficiency
7. `20-observability.md` - Logging and metrics
8. `30-error-handling.md` - Resilience
9. `40-api-design.md` - Contract standards
10. `50-security-and-testing.md` - Quality gates
11. `100-tech-stack.md` - Local project specifics

## Operating Rules
- Re-read `AGENTS.md` and `.agent/SYSTEM.md` at major task boundaries
- Research current documentation before changing tooling or provider config
- If confidence drops or progress stalls, use live web research instead of repeating the same attempt
- If a required capability is missing, resolve it through `scripts/skill.sh` instead of improvising
- Treat tests, lint, and security verification as part of done

## Usage
- `Antigravity`: load this file, then `.agent/SYSTEM.md`
- `Codex`, `Claude Code`, `OpenCode`: follow their documented repo entry points instead of linking to deprecated third-party shims
