---
name: nolan-git-commit
description: >-
  Prepare and create Git commits using Nolan Nguyen's workflow. Use when the
  user asks to commit, craft a commit message, stage changes, update a branch,
  split work into atomic commits, or prepare a pull request. Enforce one-line
  Conventional Commit messages, pull with rebase before each commit, require
  test evidence in pull requests, exclude unrelated changes, and never add
  Co-authored-by trailers.
---

# Nolan Git Commit

Create focused, reviewable commits without losing or rewriting unrelated user work.

## Plan atomic commits

1. Divide the change by independent concern before staging.
2. Create multiple small commits when changes can be reviewed or reverted
   independently. Never put a multi-concern task into one large commit.
3. Keep implementation and its directly related tests in the same commit.
4. Keep each commit buildable and internally coherent where practical.
5. Separate mechanical refactors, behavior changes, documentation, generated
   files, and dependency updates when they are logically independent.
6. Do not split by arbitrary file or line counts; split by intent.

## Inspect

1. Determine the repository root and current branch.
2. Run `git status --short`, inspect staged and unstaged diffs, and review recent commit style.
3. Identify unrelated, generated, secret-bearing, or accidental files. Do not stage them.
4. If the working tree contains changes outside the requested commit, preserve them and stage only explicit paths or hunks.

## Verify before synchronization

1. Run the relevant tests or checks for the intended commit.
2. Confirm the repository has a configured upstream before pulling.
3. Do not hide a dirty working tree with an automatic stash unless the user explicitly authorizes it.

## Rebase before commit

1. Fetch and run `git pull --rebase` against the current branch's configured upstream immediately before committing.
2. If local changes prevent the rebase, stop and explain the safe options. Do not reset, discard, force, or auto-stash changes.
3. If conflicts occur, stop and report the conflicted paths. Resolve only with explicit authorization when the correct resolution is not already established by the task.
4. Re-run relevant verification after a rebase changes the base or code under test.

## Stage deliberately

1. Reinspect `git status --short` and the final diff.
2. Stage only files or hunks belonging to one logical change.
3. Never use broad staging when unrelated changes are present.
4. Check the staged diff with `git diff --cached --check` and `git diff --cached`.

## Write the message

Use exactly one line:

```text
<type>(<scope>): <summary>
```

Rules:

- Prefer `feat` for a user-visible capability and `fix` for a defect correction.
- Use another Conventional Commit type only when it is more accurate: `docs`, `refactor`, `test`, `chore`, `build`, `ci`, `perf`, `style`, or `revert`.
- Keep the scope short and meaningful; derive it from the affected component, package, or domain.
- Write the summary in imperative mood, lowercase where natural, with no trailing period.
- Keep the whole message concise and on one line.
- Do not add a body, footer, issue trailer, generated-by marker, or `Co-authored-by` trailer unless the user explicitly requests a specific non-coauthor trailer.

Examples:

```text
feat(queue): add delayed job scheduling
fix(replication): preserve backlog offset after reconnect
docs(architecture): document proxy request flow
refactor(auth): simplify token validation
```

## Commit and report

1. Commit with the approved one-line message.
2. Verify with `git status --short` and `git log -1 --format='%h %s'`.
3. Report the commit hash, exact subject, verification performed, and any remaining changes.
4. Never amend, push, force-push, merge, tag, or create a pull request unless separately requested.

Repeat synchronization, selective staging, verification, and reporting for each
planned commit.

## Prepare a pull request

Only create or update a pull request when explicitly requested.

1. Rebase on the intended base branch and verify the complete branch diff.
2. Confirm the commit series is ordered, focused, and free of fixup commits,
   unrelated changes, secrets, generated local state, and co-author trailers.
3. Run the relevant final checks across the complete branch.
4. Use the repository's pull request template. If none exists, structure the
   body with:
   - Summary: what changed and why.
   - Changes: the main logical changes.
   - Unit and automated tests: exact commands and results.
   - Manual tests: exact steps and observed results.
   - Impact: compatibility, performance, security, and operations where relevant.
   - Risk and rollback: known risks and a practical recovery path.
5. Write `Not run` with a reason for any applicable test category that was not
   executed. Never imply that unrun tests passed.
6. Keep the title concise and use the same Conventional Commit form when the
   repository does not define another convention.
7. Report the pull request URL and any remaining risks or skipped checks.
