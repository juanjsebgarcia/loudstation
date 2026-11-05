# 0008: Faster and truer detection after a replug

Date: 2026-11-05. Status: accepted. Builds on 0003 and 0006, and takes up the `TransferCount` idea that 0003 deferred.

## Context

On 2026-11-05 the speaker display lost its sound at replug, but an app (Spotify) held the device open, and every probe for nearly five minutes reported it working (see the discoveries for that date). Separately, an ordinary replug took about a minute from the last display event to the fix. Both should be faster, and neither may lead to cycling a display that has sound.

## Decisions

- **The kernel engine has the last word.** A probe samples the matching `DCPAVAudioDriver` before and after its window. If the same engine was running at both ends and its `TransferCount` did not move in at least three passes through its buffer, the probe reports silence, even if Core Audio's (estimated) clock advanced. The rule only ever turns "working" into "silent" on positive evidence of a stalled engine. Missing counters, an unknown buffer length, an idle engine, a different registry entry (a relink), a counter that went back, or two engines sharing a UID give no evidence, and the probe's own callbacks decide as before. The rule is `engineStalled` in Core, with unit tests.
- **The first check runs 5 s after a display event, not 12 s.** Checking early is harmless. The policy still refuses to fix until 12 s after the last topology change, and an early silent verdict only starts confirmation.
- **Only a screen arriving or leaving starts a check,** or a display's sound device appearing or going in Core Audio (`kAudioHardwarePropertyDevices`). Mode, position and main-screen events no longer start or put off a check. On the first replug test (2026-11-05 12:47), events kept arriving for about a minute after the plug-in, and each restarted the 5 s wait, so the first check ran 59 s after the plug-in. As a backstop, a burst of qualifying events delays the first check by at most 10 s from its first event (`eventCheckDelay`). Each event's type is now logged, to see which events macOS sends.
- **Every display event holds off fixing,** not only a replug: the policy's 12 s settle restarts on mode, position and main-screen changes too, so an earlier check never leads to cycling a display while macOS is still rearranging screens.
- **The confirming probe starts as soon as the first silent verdict lands.** A stuck probe blocks for about 10 s on its own. The rule is unchanged: two real silent verdicts at least 10 s apart, and a verdict that comes back too soon still waits out the rest of the gap.
- **No final probe on a fresh verdict.** An automatic fix probed once more before cycling, another 10 s on a stuck display. It now does so only when the latest silent verdict is more than 3 s old (`needsFinalProbe`). A dead link does not recover by itself, and every path to a fix ends in a fresh confirming probe anyway, so this probe was a repeat.

- **After a fix, only displays that were working are checked for collateral damage,** at the same time as the fixed display. A display already silent cannot be knocked out, and each silent one costs a 10 s probe. The CLI still checks every other display, since it has no earlier state.
- **A probe waits once for its start, not twice.** See the discoveries for 2026-11-05 13:11: the second wait always ran out on a working display, adding 15 s to every such check.

- **Waiting for the microphone is now an option, off by default** (**Pause Fixing While Microphone Is Active**), revising 0003. While the monitor speakers are silent, a call through them is already spoilt, so a 3 s blackout helps more than it hurts. And any microphone use counts, dictation included: on 2026-11-05 dictating into iTerm2 held a fix for 22 s. The full-screen wait stays on.

## Effect

An ordinary replug goes from about 60 s (last event to cycle) to about 26 s: 5 s, a 10 s stuck probe, a second 10 s stuck probe, then the cycle. A dead device held open by an app is caught by the first check, about 6 s after the event, and fixed after about 17 s, when a third verdict spans the 10 s gap.

## Rejected

- **A stuck verdict before `AudioDeviceStart` returns** (after about 3 s, from a stalled counter and no callbacks), which would cut each idle probe from 10 s to 3 s. A slow-starting sink (a TV or receiver) also shows no transfers until it starts, so two such early verdicts could cycle a healthy display. The `'stop'` from a blocked start stays the evidence for an idle device.
- **Dropping the settle time or the 10 s gap.** Cycling one display while others still negotiate can break a neighbour's audio, and a single verdict must never be enough.
