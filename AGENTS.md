@RTK.md

# gstack

gstack skills are installed and available on demand. `/browse` is a fast headless-Chromium option for QA/scraping-style browsing tasks — use it when it fits, but it does not replace the built-in `mcp__claude-in-chrome__*` tools (which run in the real logged-in Chrome session); keep using whichever fits the task.

Available gstack skills: /office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review, /design-consultation, /design-shotgun, /design-html, /review, /ship, /land-and-deploy, /canary, /benchmark, /browse, /connect-chrome, /qa, /qa-only, /design-review, /setup-browser-cookies, /setup-deploy, /setup-gbrain, /retro, /investigate, /document-release, /document-generate, /codex, /cso, /autoplan, /plan-devex-review, /devex-review, /careful, /freeze, /guard, /unfreeze, /gstack-upgrade, /learn

# Development workflow

For every substantial feature, bug fix, or refactor:

1. **Inspect and plan.** Read project instructions and relevant code. Define the expected behavior and verification steps. Give a short plan, then proceed without waiting for approval unless a consequential decision requires user input.
2. **Implement.** The current lead agent owns the task through completion, including implementation, integration, and verification.
3. **Delegate selectively.** Use helpers only for a specific investigation or a clearly separable implementation task. Give each helper a bounded scope and expected output. Use separate worktrees for concurrent code changes. Keep small, straightforward tasks with the lead agent. Prefer Codex or Claude as lead. Use Gemini, Antigravity, or Cursor for suitable bounded tasks when available. Choose by the actual model and available tools, not just the provider name.
4. **Independent review.** After implementation, request a separate reviewer—preferably Claude when Codex leads, or Codex when Claude leads. The reviewer must inspect the actual diff and relevant surrounding code, check the original requirements, and report concrete bugs, regressions, missing requirements, or important test gaps with file references and failure scenarios. Reviewers should not edit files.
5. **Resolve and verify.** Evaluate review findings, fix valid issues, and run appropriate checks. Verify the affected user flow when applicable. Request another focused review if fixes materially change the implementation.
6. **Report.** Finish with what changed, what was verified, and unresolved issues. State whether independent review actually happened.

## Operating rules

- Apply this automatically to later implementation prompts.
- For questions or trivial edits, use a proportionate shorter process.
- Use available T3 delegation tools when supported.
- If cross-provider delegation is unavailable, use an independent same-provider reviewer if possible and disclose that substitution.
- If no independent reviewer is available, perform a separate review pass and explicitly disclose the limitation.
- Never claim delegation, review, or verification that did not occur.
- This workflow does not itself authorize merging, deployment, purchases, or changes to access permissions.
