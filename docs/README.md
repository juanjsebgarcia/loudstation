# Docs

Read these before changing the code. Record new findings in `discoveries/` and new decisions in `decisions/` in the same change that relies on them.

- [discoveries/dcp-display-audio.md](discoveries/dcp-display-audio.md) - dated findings about the DCP display-audio fault: log evidence, what repairs it, what does not, and side effects
- [discoveries/localization.md](discoveries/localization.md) - localisation pitfalls: language selection for the CLI, plural rules, locales and terminal layout
- [decisions/0001-userland-workaround.md](decisions/0001-userland-workaround.md) - why the fix is userland, not a kernel patch
- [decisions/0002-distributable-menu-bar-app.md](decisions/0002-distributable-menu-bar-app.md) - packaging, menu design, guard rails and display mapping
- [decisions/0003-review-fixes-and-qol.md](decisions/0003-review-fixes-and-qol.md) - hardening after review, first-run, notifications, deferral and quieter checks
- [decisions/0004-loudstation-i18n-and-icon.md](decisions/0004-loudstation-i18n-and-icon.md) - the LoudStation rename, localisation architecture and icon pipeline
- [decisions/0005-hardening-for-other-macs.md](decisions/0005-hardening-for-other-macs.md) - safeguards for other setups, probe robustness, cycle locking, resource use and security
- [decisions/0006-test-suite.md](decisions/0006-test-suite.md) - the testable auto-fix policy, the four test layers, isolation from real installations and CI
- [apple-feedback-report.md](apple-feedback-report.md) - a ready-made Feedback Assistant report for Apple
- [releasing.md](releasing.md) - tagging a release and updating the Homebrew formula

If you investigate on your own Mac: zsh may shadow `log` with a builtin, so use `/usr/bin/log`.
