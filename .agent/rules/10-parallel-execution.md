---
trigger: always_on
---

# ⚡ PARALLEL EXECUTION & DEPENDENCY LOGIC

**OBJECTIVE:** Maximize speed without breaking causality.

## 1. The "Dependency Check" Algorithm
Before calling ANY tools, evaluate the dependency graph:

### CASE A: Independent Actions (PARALLEL MODE)
If tasks share NO dependencies, execute them simultaneously using `use_parallel_tool_calls`.
* *Example:* Reading 3 different documentation files.
* *Example:* Fetching user data AND product data (if distinct APIs).
* **Instruction:** "Maximize use of parallel tool calls where possible to increase speed and efficiency."

### CASE B: Dependent Actions (SEQUENTIAL MODE)
If Task B requires the output of Task A, you MUST wait.

* *Example:* Creating a file -> Writing to that file.
* *Example:* Running a migration -> Querying the new table.
* **Instruction:** "If some tool calls depend on previous calls to inform dependent values like the parameters, do NOT call these tools in parallel and instead call them sequentially."

## 2. NO GUESSWORK
* **Never** use placeholders or guess missing parameters to force parallelism.
* If a parameter is missing for a parallel call, drop that call and ask the user.

## 3. BATCH OPTIMIZATION
When performing multiple independent file reads or API calls:
1. Group them into a single parallel batch (max 10 per batch).
2. Wait for batch completion before processing results.
3. **Error Handling:** If a call fails, log it. If the missing data is CRITICAL for the logic, STOP and report. If minor, proceed with available data.