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

ClaudeGlance signs you in through your browser using an OAuth 2.0 PKCE flow and
stores the resulting access/refresh tokens in its **own local macOS Keychain
item** (`ClaudeGlance-credentials`). Tokens are sent only to Anthropic's own
OAuth token and usage endpoints over HTTPS, and are never logged or transmitted
anywhere else. Reports about how the app stores, refreshes, transmits, or exposes
those tokens are especially welcome.

> Note: the browser flow reuses Claude's **public** OAuth client (the same public
> client the Claude Code CLI uses; no client secret is involved). There is no
> separate third-party client registration for usage apps, so this reuse is
> unofficial and could change if Anthropic alters that client.
