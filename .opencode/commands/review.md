---
description: Perform adversarial code review
agent: review
subtask: true
---

Review the current codebase or the specified files following these standards:
1. Read `.agent/skills/code-review-checklist/SKILL.md`
2. Check architecture boundaries, dependency direction, and failure-mode handling
3. Check for security vulnerabilities (OWASP Top 10)
4. Assess performance risks, especially N+1, unbounded work, and slow critical paths
5. Assess unit, integration, edge-case, and e2e coverage
6. Report findings with severity levels
