# ZeroLose V2 Tracks 1–3 Integration Gate

This document records the integration boundary for the first three ZeroLose V2 roadmap tracks after the Computer Agent Runtime V2 work landed on `main`.

## Scope

- Track 1: ZeroLose V2 foundation/runtime contracts.
- Track 2: Unified Tool Fabric and PolicyKernel execution boundaries.
- Track 3: append-only persistence, authority-free checkpoints, scoped memory, deterministic replay, and external mutation reconciliation.

## Integration baseline

- Target branch: `main`.
- Main SHA at retarget: `456aeca3acc3e193121244391df47823ca03f6bb`.
- Track 3 pre-integration head: `161e2a685f649e9a7bac6b4389eca2c2e0978b2e`.
- PR: #19.

## Required gates

- [ ] PR mergeability is clean against current `main`.
- [ ] Repository workflow passes for the retargeted PR merge ref.
- [ ] ZeroLose V2 architecture guards pass.
- [ ] Repository-wide verification passes.
- [ ] No V2 `[ACTION]` execution primitive is introduced.
- [ ] No credential material or executable authority is persisted.
- [ ] Replay remains non-mutating and independent of live network/model/input execution.
- [ ] Physical computer mutations remain behind Tool Fabric + PolicyKernel.

This is an integration evidence document only. It does not change runtime behavior or relax any roadmap invariant.
