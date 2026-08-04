# Copilot Change Scope Guardrails

This repository prioritizes behavior stability over opportunistic refactors.

## Hard Rule
When implementing a requested change, do only the minimum required for that request.

## Must Ask First (Explicit User Approval Required)
- Any refactor, cleanup, or "optimization" not required to satisfy the request.
- Any behavior change outside the requested scope.
- Any change to window-routing/maximize conventions (`KIOSK-D-n` and `*Maximized*`).
- Any change to startup/session sequencing, service topology, or file locations beyond the requested target.
- Any documentation rewrite beyond sections directly impacted by the requested change.

## Implementation Expectations
- Prefer narrow diffs and keep unrelated logic untouched.
- Preserve existing behavior unless the user explicitly asks to change it.
- If you identify a possible improvement outside scope, propose it separately and wait for approval before editing.
- In fixes, do not bundle additional "nice-to-have" edits.

## If Unsure
Stop and ask for confirmation before making the extra change.
