# Security Policy

## Supported versions

ClaudeGlance is a small project; only the **latest release** receives security
fixes. Please make sure you're on the most recent version before reporting.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report vulnerabilities privately via GitHub's
[**Report a vulnerability**](https://github.com/broots144/claudeglance/security/advisories/new)
button (under the repository's **Security** tab). If that's unavailable, contact
the maintainer through their GitHub profile.

Please include:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept
- The affected version and your macOS version

You can expect an initial response within a few days. Once a fix is available,
we'll coordinate disclosure and credit you if you'd like.

## Scope notes

ClaudeGlance reads your Claude Code OAuth token from the **local macOS Keychain**
(`Claude Code-credentials`) and sends it only to Anthropic's own usage endpoint
over HTTPS. The token is held in memory and is never written to disk, logged, or
transmitted anywhere else. Reports about how the app stores, transmits, or
exposes that token are especially welcome.
