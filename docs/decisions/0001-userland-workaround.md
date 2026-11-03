# 0001: Work around the DCP audio fault from userland, not the kernel

Date: 2026-11-03. Status: accepted.

## Context

Display audio over the M1 Max's DCP fails at hot-plug and stays dead (see `docs/discoveries/dcp-display-audio.md`). The evidence points to Apple's DCP coprocessor firmware and `DCPAVFamily` kernel code.

## Decision

Build a per-user LaunchAgent that detects the stuck state and remediates it with display-configuration calls, rather than attempting any kernel or firmware patch.

## Reasons

- DCP firmware runs on a separate coprocessor and is Apple-signed; it cannot be modified.
- Apple Silicon locks kernel text after boot (KTRR), so even a third-party kext under Reduced Security cannot hot-patch Apple's kernel code.
- Asking users to lower their Mac's security (Reduced Security, SIP off) is not acceptable for a tool meant for anyone.
- A userland agent needs no privileges and can be removed by deleting one plist.

## Remediation ladder (to be validated by the PoC)

1. Mode switch of the speaker display and back (public `CGConfigureDisplayWithDisplayMode`).
2. Software disable/enable of the speaker display (private SkyLight `SLSConfigureDisplayEnabled`).
3. Fallback: move the default output to a working device so playback continues.
