# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- **Preferred:** GitHub's private vulnerability reporting — the **Security** tab →
  *"Report a vulnerability."*
- **Or email:** `security@roculus.dev`
  *(maintainers: point this at a monitored inbox before relying on it.)*

Include enough detail to reproduce. **Never paste real tokens, refresh tokens, or
other credentials into a report.**

## Scope

**In scope:** the Studio plugin (`plugin/`) and the in-game runtime (`runtime/`)
in this repository.

**Out of scope:** the Roculus dashboard backend, which is separate and not in this
repo. The Bridge is a thin client — it authenticates to, and is authorized by,
that backend, and holds no privileged secrets of its own. A customer's per-place
token is supplied at install time and stored only in their own place file.

## What to expect

We'll acknowledge valid reports as quickly as we can and keep you posted on a fix.
There's no paid bounty at this time; credit is given for valid reports if you want it.
