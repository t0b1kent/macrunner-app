# Security Policy

MacRunner is a free macOS app for running Windows games on Apple Silicon. It is maintained by one developer, [Timur Ravilov](https://macrunner.app/about/). Thank you for helping keep its users safe.

## Supported versions

Only the latest release on the [Releases page](https://github.com/MacRunnerApp/macrunner-app/releases) receives security fixes. Please check that a problem still occurs in the current release before reporting it. MacRunner can update itself from inside the app.

## Reporting a vulnerability

**Please do not report security problems in public issues, discussions or pull requests.**

Report privately in one of these ways:

1. **GitHub private vulnerability reporting (preferred):** open the [Security tab](https://github.com/MacRunnerApp/macrunner-app/security) and choose **Report a vulnerability**, or go straight to [this form](https://github.com/MacRunnerApp/macrunner-app/security/advisories/new). Only you and the maintainer can see the report.
2. **Email:** zaryadradostitobi@gmail.com, subject starting with `MacRunner security`.

Please include:

- the MacRunner version and build (shown in the app's About window) and your macOS version;
- what an attacker can do and under which conditions;
- steps to reproduce, or a proof of concept;
- whether the problem is already public or known to others.

## What happens next

- I aim to acknowledge reports within 7 days. This is a one-person project, so replies can occasionally take longer.
- I will confirm whether the problem is reproducible, work on a fix and agree a disclosure date with you. Fixes ship in a new release; for confirmed issues I can publish a GitHub security advisory and credit you if you wish.
- There is no paid bug bounty.

## Scope

In scope:

- the MacRunner app and its installers published in this repository's releases;
- the update feed (`https://macrunner.app/appcast.xml`) and downloads linked from this repository;
- the website [macrunner.app](https://macrunner.app).

Out of scope:

- Windows programs and games you run with MacRunner. Wine is a compatibility layer, not a sandbox: a Windows program runs with the same macOS permissions as the app and can read the files your user account can read. Only run software you trust.
- Vulnerabilities in upstream projects (Wine, FEX-Emu, DXMT and other components listed in [CREDITS.md](CREDITS.md)). Please report those upstream. Do tell me if a MacRunner release ships an affected version.
- The HyperBridge engine source, which has its own policy in [t0b1kent/hyperbridge](https://github.com/t0b1kent/hyperbridge/security/policy). Either repository is fine if you are unsure where an issue belongs.

## Verifying downloads

Releases are signed with an Apple Developer ID and notarized by Apple. To check a downloaded copy:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/MacRunner.app
spctl --assess --type execute --verbose /Applications/MacRunner.app
```

`spctl` should report `accepted` and `source=Notarized Developer ID`.
