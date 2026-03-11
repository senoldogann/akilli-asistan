# 02 - RESEARCH ESCALATION & ANTI-LOOP PROTOCOL

> **Principle:** "When certainty drops or progress stalls, change evidence source before changing confidence."

## 1. MANDATORY RESEARCH TRIGGERS
Use live web research or current primary-source documentation before answering when any of these are true:
- The information may have changed recently: models, libraries, provider configs, APIs, prices, policies, security guidance, release behavior, or best practices.
- The task asks for the "best", "latest", "current", "recommended", or "official" approach.
- The agent is choosing between competing tools, versions, frameworks, or provider settings.
- The agent is less than highly confident and the answer could create rework or incorrect configuration.
- The agent is blocked by missing context that can be resolved through official documentation or current web search.

## 2. SOURCE PRIORITY
- Prefer official product documentation, standards bodies, release notes, changelogs, and security advisories.
- Use third-party sources only when official documentation is missing or insufficient.
- When research affects a recommendation or config change, cite or name the source in the final response.

## 3. ANTI-LOOP RULE
The agent must not keep repeating the same non-progressing action.

Trigger the anti-loop protocol when:
- The same command, tool call, or search is repeated without producing materially new evidence.
- Two consecutive attempts fail for the same reason.
- The agent is about to "try again" without a changed hypothesis.
- The agent is filling time with internal speculation instead of gathering new evidence.

## 4. ANTI-LOOP PROTOCOL
When the loop trigger fires, do this in order:
1. Stop repeating the same action.
2. State the blocker in one sentence.
3. Change strategy: inspect logs, read current docs, run web search, or ask the user for a missing fact.
4. Resume only after the strategy has changed and new evidence exists.

## 5. PROVIDER-SPECIFIC EXPECTATION
- `Antigravity`: use native `web_search` or approved MCP research tools when available.
- `Codex`: use live web search when launched with `--search` or the project research wrapper.
- `Claude Code`: use `WebSearch` / `WebFetch` instead of guessing when the task is temporally unstable or blocked.
- `OpenCode`: use `websearch` / `webfetch`; never ignore `doom_loop` protection.

## 6. FAIL-SAFE
If live research is required but unavailable in the current runtime:
- Say that current verification is blocked by missing web access.
- Do not present stale memory as confirmed fact.
- Ask for a research-enabled run or proceed only with clearly labeled uncertainty.
