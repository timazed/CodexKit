# Security Policy

If you discover a security issue, report it through GitHub Issues.

## Reporting

- Open an issue at: `https://github.com/timazed/CodexKit/issues`
- Use title prefix: `[Security]`
- Include:
  - affected version/tag
  - impact summary
  - reproduction steps
  - proof-of-concept (if available)

## Scope Notes

This SDK includes auth flows, local persistence, and host tool execution plumbing. Sensitive areas to review:

- OAuth redirect and loopback handling
- secure store usage for session material
- tool execution and approval routing
- local state serialization/deserialization
