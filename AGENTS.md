@RTK.md

# gstack

gstack skills are installed and available on demand. `/browse` is a fast headless-Chromium option for QA/scraping-style browsing tasks — use it when it fits, but it does not replace the built-in `mcp__claude-in-chrome__*` tools (which run in the real logged-in Chrome session); keep using whichever fits the task.

Available gstack skills: /office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review, /design-consultation, /design-shotgun, /design-html, /review, /ship, /land-and-deploy, /canary, /benchmark, /browse, /connect-chrome, /qa, /qa-only, /design-review, /setup-browser-cookies, /setup-deploy, /setup-gbrain, /retro, /investigate, /document-release, /document-generate, /codex, /cso, /autoplan, /plan-devex-review, /devex-review, /careful, /freeze, /guard, /unfreeze, /gstack-upgrade, /learn

# Development workflow

## Purpose

Complete the user's requested development work with one accountable
lead agent. Delegate well-defined pieces when helpful, independently
review substantial changes, and verify the final integrated result.

Apply this workflow automatically to future development requests.
A direct instruction from the user can change its scope.

## 1. Identify the lead agent

The agent receiving the user's request is the lead agent.

The lead agent must:
- Understand the request and define what successful completion means.
- Inspect relevant project instructions and existing code.
- Decide which work to do directly and which work to delegate.
- Give helpers complete assignments.
- Review and integrate helper results.
- Resolve review findings.
- Verify the final result.
- Give the user an accurate completion report.

Prefer Codex or Claude as lead when choosing a lead is possible.
If another provider receives the request, do not silently switch
providers or assume a different lead exists.

The lead remains accountable even when helpers perform most of
the implementation.

## 2. Check what delegation is actually available

Before delegating, inspect the available tools and supported agent
or model targets.

A provider connected to T3 Code is not necessarily available as
a callable subagent.

- Use a supported T3 delegation tool when available.
- Select the intended provider and actual model explicitly when
  the tool supports that choice.
- Do not invent commands, model names, or delegation capabilities.
- Do not treat mentioning a provider in a prompt as proof that
  work was sent to that provider.
- Do not start a separate conversation that cannot return its
  results to the lead unless that handoff is supported.

If Cursor or Gemini cannot be called:
- Continue the task using the tools that are available.
- Use another appropriate helper if useful.
- Briefly disclose the substitution or lack of delegation.
- Do not stop solely because a preferred helper is unavailable.

Do not claim that delegation saved subscription allowance unless
usage information supports that statement.

## 3. Understand the request and define completion

Before editing:
- Read applicable project instructions.
- Inspect the relevant code, existing patterns, and available checks.
- Identify the behavior the user wants.
- Identify constraints stated by the user or project.

For substantial changes, state a short plan that includes:
- The expected behavior after the change.
- The main areas likely to change.
- How the result will be verified.
- Any work you intend to delegate.

A substantial change includes:
- A new feature.
- A bug fix whose cause is uncertain or crosses several components.
- A refactor that changes behavior or shared interfaces.
- Changes to authentication, authorization, data persistence,
  migrations, or important business rules.

A short path is appropriate for:
- Answering a question without changing code.
- Fixing a typo.
- A small, mechanical edit with no meaningful behavior change.

Do not require a planning conversation for every task.
Proceed after stating the plan unless a material ambiguity requires
the user's answer.

Ask for clarification when different reasonable interpretations
would produce meaningfully different behavior. Investigate anything
that can be answered from the repository before asking the user.

## 4. Decide what to delegate

The lead should usually keep:
- Decisions about how components fit together.
- Requirements with several plausible interpretations.
- Changes to shared interfaces used by several components.
- Debugging where the cause has not yet been narrowed down.
- Integration of work from multiple helpers.
- Final assessment of review findings.
- Final verification of the complete user flow.

Proactively consider Cursor or Gemini for work with clear rules,
limited scope, and an output the lead can check.

Examples:
- Find where a particular behavior is implemented.
- Trace a request from a UI action through the API to storage.
- Summarize relevant documentation with source links.
- Apply a repetitive edit to an explicit list of files.
- Implement an isolated UI element using an existing pattern.
- Add focused tests for behavior already specified by the lead.
- Investigate one specific question and return evidence.

These are starting preferences, not assumptions that a provider
is always better or worse at a particular task. Consider the actual
model, tool access, observed results, and reported usage limits.

Delegate only when:
- The helper can understand the assignment without reconstructing
  the entire project.
- Its output will contribute directly to the user's request.
- The lead can check whether the output is correct.
- Giving and reviewing the assignment is likely to be worthwhile.

Keep very small tasks with the lead when explaining the assignment
would take more effort than completing it.

Start with at most two helpers working concurrently. Increase
concurrency only when assignments remain independent and results
can be reviewed promptly.

## 5. Give every helper a complete assignment

Every delegated assignment must include:

A. Objective
The exact question to answer or behavior to implement.

B. Relevant context
The user requirement, relevant files, existing patterns, and any
decisions the helper must follow.

C. Allowed scope
The files or subsystem the helper may inspect or modify.
State whether the assignment is read-only or allows edits.

D. Constraints
Interfaces to preserve, unrelated areas to avoid, and any
project-specific requirements.

E. Required output
For investigation:
- Findings.
- File paths and relevant functions or line references.
- Evidence supporting the findings.
- Uncertainties or unanswered questions.

For implementation:
- Changed files.
- Description of the resulting behavior.
- Checks performed and their results.
- Remaining issues or assumptions.

F. Completion condition
An observable condition that tells the helper when to stop.

G. Escalation condition
Tell the helper to report back before expanding its assignment
if it discovers that it needs to change shared interfaces, edit
outside its scope, or make an unresolved product decision.

Do not send vague assignments such as:
- "Improve the backend."
- "Handle authentication."
- "Make sure everything works."

Example investigation assignment:

"Find how CSV exports are currently generated. Inspect the table
components and export utilities. Do not edit files. Return the
relevant file paths, the call flow, reusable functions, and any
limitations. Stop when you have enough evidence to recommend the
existing pattern for a new export button."

## 6. Prevent conflicting edits

For helpers that edit code concurrently:
- Use separate worktrees or another supported isolated workspace.
- Give each helper a distinct scope.
- Do not let multiple helpers edit the same shared files at once.
- Agree on interfaces before work that depends on those interfaces.
- Make sure each helper has the current workflow instructions.

Read-only helpers may inspect the same checkout.

If workspace isolation is unavailable, serialize code edits.
Do not allow simultaneous edits merely to keep agents busy.

The lead must inspect each helper's changes before integrating
them. Do not overwrite unrelated user changes or accept an entire
patch without reading it.

## 7. Implement and check the change

Follow the project's existing architecture and conventions.
Keep changes focused on the user's request.

While implementing:
- Check important assumptions against code or documentation.
- Add or update tests when they meaningfully verify new behavior
  or guard against the reported bug.
- Do not add tests that merely repeat implementation details.
- Run the checks appropriate to the changed area.
- Inspect helper output rather than relying only on its summary.

A helper reporting "tests passed" does not establish that the
combined application works after integration.

## 8. Request independent review

After a substantial change is implemented and integrated, request
a separate review before declaring completion.

Preferred reviewer:
- Claude when Codex is lead.
- Codex when Claude is lead.
- Otherwise, a capable available agent that did not implement
  the change.

A different provider is preferred when practical, but a separate
same-provider reviewer is acceptable.

Give the reviewer:
- The original requirement and acceptance conditions.
- The exact branch, worktree, or diff to inspect.
- The relevant base revision.
- Known constraints.
- Instructions to inspect surrounding code as needed.

The reviewer must:
- Read the actual changed code.
- Check it against the original requirement.
- Look for concrete bugs, regressions, missing requirements,
  and important gaps in verification.
- Explain how each reported problem could occur.
- Give file references.
- Distinguish confirmed findings from uncertain concerns.
- Make no edits.

Do not give the reviewer only the implementer's summary.
Do not ask for a required number of findings.
"No actionable findings" is a valid result.

## 9. Resolve findings and verify the integrated result

The lead must assess each actionable finding.

For each finding:
- Fix it if valid.
- Explain why it does not apply if rejected.
- Report it as unresolved if it cannot be addressed.

Do not accept a finding merely because a reviewer reported it.

After fixes:
- Run the relevant checks again.
- Verify that the original acceptance conditions are met.
- Exercise the affected user flow when practical.

For a web application, this may require checking the UI, the
request it sends, the server response, and the resulting data.
Compilation alone is not proof that the user flow works.

If review fixes substantially change the logic or introduce a
new interface, request a focused second review of those changes.
Do not repeat reviews indefinitely for cosmetic edits.

If no separate reviewer is available:
- Perform a distinct review pass after implementation.
- Explicitly report that independent review was unavailable.
- Do not describe self-review as independent review.

## 10. Report completion accurately

The final response should state:
- What changed and the resulting behavior.
- Which checks actually ran and their results.
- Whether independent review occurred and which agent performed it.
- Any unresolved issue, failed check, or verification limitation.

Distinguish clearly between:
- A check that passed.
- A check that failed.
- A check that was not run.

Never claim that a helper, reviewer, test, browser check, or
integration step happened unless it actually happened.

## 11. Continuity and authorization

For follow-up requests in the same task:
- Preserve the original requirements unless the user changes them.
- Update the plan when new information changes the work.
- Reuse completed investigations when still applicable.
- Review and verify the newly changed behavior proportionately.

Continue through implementation, review, corrections, and
verification without requiring the user to prompt for each phase.

This workflow does not itself authorize publishing, merging,
deployment, purchases, deletion of unrelated data, or changes
to access permissions. Follow the user's actual authorization
and the environment's approval requirements.
