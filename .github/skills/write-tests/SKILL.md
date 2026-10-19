---
name: write-tests
description: Write meaningful Replica tests. Use when adding regression coverage, testing new behavior, or changing existing automated tests.
---

# Writing meaningful tests

## Establish the contract

Read the [root instructions](../../../AGENTS.md), [shared coding conventions](../../../docs/coding-conventions.md), and [testing and review guide](../../../docs/testing-and-review.md), then the affected project's instructions and relevant guides. The shared guide owns test-quality criteria and the independent-writer policy.

Identify the accepted behavior, public interface, and existing coverage. For each proposed case, state the distinct regression it catches and why existing cases would miss it. Drop redundant cases and incidental assertions. Complete this step when every retained case has an expected outcome grounded in requirements rather than current implementation.

## Choose the writer

Apply the shared guide's independent-writer policy. For substantial behavior changes and nontrivial bug fixes, delegate once to an available code-capable agent with permission to edit tests. Use a synchronous task unless implementation can safely proceed in separate files while the writer works.

If you are already the assigned test writer, write the tests directly; this assignment is the independent pass.

Give the writer a self-contained assignment containing:

- The relevant user request and accepted requirements, separately from implementation suggestions.
- The bug reproduction or behavior to add, including known failure and boundary cases.
- Affected interfaces and paths, existing coverage, project guidance, and any implementation already completed.
- Ownership of named test files and necessary test fixtures; production changes remain with the implementation agent.
- A bounded result: implement the smallest distinct coverage, run focused checks, and return changed files, the regression each case catches, observed red/green evidence, and unresolved requirements or production defects.

When behavior is unclear, resolve it with the user before asking the writer to encode it. Small changes follow the same process directly without delegation.

## Write and verify

Use the existing runner and repository test patterns. Establish a meaningful failing case where feasible, then run the smallest command covering the completed change. Preserve unrelated work when checking pre-fix behavior; prefer an isolated reproduction over reverting a dirty worktree.

Review the resulting tests against the shared criteria. Ensure mocks leave the behavior under test real, expectations come from the contract, and every added case protects a distinct regression. Resolve reported production defects in the implementation agent, then rerun affected tests and follow the project's final-check requirements.

Finish only when the retained cases prove their intended outcomes, or explicitly report the blocker and unverified behavior. Distinguish observed results from expected coverage, and maintenance simplification from measured runtime savings. Keep the handoff concise; the per-case rationale belongs in the writer's working result, not boilerplate code comments or a new tracking document.
