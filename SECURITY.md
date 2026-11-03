# Security policy

## Supported versions

Only the latest release gets security fixes. The app tells you when a newer release is out, and `loudstation --version` shows the version you have.

## Reporting a vulnerability

Please report it privately, not in a public issue. Go to **Security** > **Report a vulnerability** on this repository ([direct link](https://github.com/juanjsebgarcia/loudstation/security/advisories/new)).

Please include:

- the version, your Mac model and your macOS version;
- what an attacker can do, and what they need first (local access, another user account, a network position);
- steps or a proof of concept that reproduce it.

This is a one-person project maintained in spare time. You should get an acknowledgement within a week. A fix ships as a new release, and a GitHub security advisory credits you unless you would rather not be named.

## Scope

In scope:

- the `loudstation` command, the LoudStation app and its login item;
- the update check;
- the log, settings and state files it writes;
- the Homebrew formula in [juanjsebgarcia/homebrew-tap](https://github.com/juanjsebgarcia/homebrew-tap).

Out of scope:

- **The display-audio fault itself.** It is a macOS bug, so report it to Apple; [`docs/apple-feedback-report.md`](docs/apple-feedback-report.md) is a ready-made report.
- **Use of a private macOS function** (`SLSConfigureDisplayEnabled`) on its own. This is documented and deliberate.
- **Attacks that need root access, or control of your user account,** because these already give full control of the Mac.
- **Display blanking that LoudStation is designed to do,** within its documented safeguards.

## How LoudStation is meant to be safe

These are the properties a report would break:

- **Least privilege:** it runs as you and needs no admin rights. It refuses to run as root.
- **One network request:** the only connection it makes is the daily update check. That is one anonymous `GET` to `api.github.com` with no cookies or credentials. Turn off Check for Updates Automatically and it makes none.
- **It never downloads or runs code.** The update check only shows a menu item. It accepts only plain version numbers, and opens only links to this repository's own release pages on github.com, in your browser.
- **Built on your Mac:** both install routes build it from source there, and it is ad-hoc signed with the hardened runtime.
- **Only its own trusted bundle:** the command borrows translations from, and opens, only a LoudStation app bundle of the same version that you or root own. Translations with mismatched format strings are rejected.
- **Careful file handling:** it writes only inside your home folder. The log and the fix lock are created owner-only and never opened through a symbolic link, and the crash-recovery record is replaced atomically. The log hides your home folder and display serial numbers.
