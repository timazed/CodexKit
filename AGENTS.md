# Repository Rules

## Branch Naming

- Use a short, descriptive, lowercase kebab-case name after one of these prefixes:
  - `feature/<name>`: New functionality or a new user-facing capability, such as `feature/conversation-export`.
  - `bugfix/<name>`: Correct existing behavior that is broken or incorrect, such as `bugfix/duplicate-stream-events`.
  - `chore/<name>`: Repository maintenance, tooling, CI, dependencies, documentation, or internal cleanup without an intended product behavior change, such as `chore/update-dependencies`.
  - `improvement/<feature>`: Enhance an existing capability's performance, reliability, usability, or design, such as `improvement/structured-request-recovery`.
- Choose the prefix by the primary purpose of the change. Use `bugfix/` for a specific defect and `improvement/` for broader enhancements to working functionality.
- Use these prefixes for new work instead of `codex/` or version-number branch names. Keep `main` as the integration branch and use tags for releases.

## Source File Size

- Keep every production source file at or below 600 physical lines.
- If a task touches a production source file that is already over the limit, split it into focused types or extensions as part of that task.
- Generated sources and vendored dependencies are exempt.
