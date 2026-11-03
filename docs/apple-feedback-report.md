# Apple Feedback Assistant report

A ready-made report for Apple's Feedback Assistant (`open -a "Feedback Assistant"`). If you are affected, file your own with your Mac's details and a sysdiagnose taken while the audio is stuck (`sudo sysdiagnose -f ~/Desktop`). Duplicate reports help Apple prioritise.

Paste the title into the title field and everything under "Description" into the description field.

## Title

M1 Max: display audio dies after multi-display hot-plug (DCP StartLink fails but reports success), stalling all audio and video playback - appears to be a regression in macOS 27

## Description

### Summary

On an M1 Max MacBook Pro with three external displays, the DCP's display-audio link setup fails during hot-plug but is reported as successful. The `DCPAVAudioDriver` engine for the affected display never produces timestamps (`_hostTime=0`), so `coreaudiod` cannot establish a timeline and every client writing to that output stalls. Video players stall too, because they wait on the audio clock. The state persists until the display's link is rebuilt. This happened occasionally on macOS 26 and happens on nearly every hot-plug on macOS 27.

### Environment

- MacBook Pro, M1 Max (T6000 kernel), 32 GB, lid closed
- macOS 27.2 (26B123)
- Three Dell monitors, all connected through the Mac's USB-C ports in DisplayPort Alternate Mode:
  - DELL U2518D on `dcpext0`, through a USB-C hub's DP-to-HDMI converter (CoreAudio transport `hdmi`). Speakers are connected to this monitor's audio line-out.
  - DELL U2520D on `dcpext1`, DisplayPort
  - DELL U2518D on `dcpext2`, DisplayPort
- No third-party kernel extensions. No third-party audio drivers in the output path (HAL plug-ins present: Apple's ParrotAudioPlugin and Zoom's virtual device, neither in use).

### Steps to reproduce

1. With the lid closed, connect three external displays so that they come up at the same time (for example after wake, or by connecting the hub).
2. Set Sound Output to one of the displays' audio devices.
3. Play audio (for example Spotify) or a video with sound (for example in Firefox or Safari).

### Expected

Audio plays through the display's audio output, and video plays normally.

### Actual

No audio plays. Players appear to start and then pause or hang. Video freezes. This repeats on every attempt until the display link is rebuilt. Restarting `coreaudiod` does not help.

### Analysis

1. At hot-plug, audio link setup fails on every DCP. Kernel log, 2026-11-03 10:56:

   ```
   (DCPEXT0) AppleDCPDPTXAudioLinkDelegate::handleStartLink Failed to get workloop   (x2)
   (DCPEXT1) AppleDCPDPTXAudioLinkDelegate::handleStartLink Failed to get workloop   (x2)
   (DCPEXT2) AppleDCPDPTXAudioLinkDelegate::handleStartLink Negotiaton already in progress.
   (DCPEXT2) AppleDCPDPTXAudioLinkDelegate::handleStartLink HDCP Startup Failed.
   (DCPEXT2) AppleDCPDPTXAudioLinkDelegate Phase two failed.
   (DCPEXT2) AppleDCPDPTXAudioLinkDelegate Enable failed.
   (DCPEXT2) DCPAVAudioInterface Failed prepareLink
   ```

   Audio link start appears to be coupled to HDCP negotiation, and concurrent negotiations across the three DCPs collide.

2. The failure is not propagated. The `DCPAVAudioDriver` `EventLog` for the same displays records `StartLink ... CommandStatus=success`.

3. From then on, every playback attempt fails the same way (`coreaudiod`, U2520D, 11:57:32):

   ```
   HALS_IOContext_Legacy_Impl::IsTimeRunning_Helper: Device 10AC50A1-0000-0000-231E-0104A5371F78 is not running.
   HALS_IOContext_Legacy_Impl::IOWorkLoop: could not establish a timeline after waiting 10000000 microseconds
   IO Stopped Context 599 after 0 frames.
   HALS_IOContext_Legacy_Impl::StartIOThread: the IO thread failed to start, Error: 1937010544 ('stop')
   ```

   with the kernel reporting:

   ```
   DCPAVAudioDriver(iop-dcpext1-nub)::stopIOEngineGated: _hostTime=0, _transferStartTimeStamp=325529135361, ...
   ```

   `_transferStartTimeStamp` stays at the value from the failed hot-plug `StartLink`, so the engine has not been re-initialised since. The IORegistry flag `"is running"` reads `Yes` while a client is attempting IO even though no frames move.

4. An IOProc that plays silence to the device gets 0 callbacks, and `AudioDeviceStart` blocks for about 10 s before returning `'stop'`. A healthy device (USB audio, built-in speakers) gets about 90 callbacks per second.

5. Video stalls are a consequence of the audio fault. `AppleAVD` and `VTDecoderXPCService` logged no errors. Firefox's NowPlaying state toggles within milliseconds of each audio failure. Video plays normally once the audio link is repaired.

### What repairs it, and what does not

- Changing the display mode (2560x1440@60 to 800x600@60 and back) does not repair it. The kernel logs no audio link or HDCP activity during the switch, and `_transferStartTimeStamp` does not change.
- Disabling and re-enabling only the affected display through SkyLight's `SLSConfigureDisplayEnabled`, while the other displays stay up, repairs it every time. The DCP tears down and re-runs the link, including HDCP (`shutdownHDCPBlock`, `abortHDCPNegotiation`, `startupHDCPBlock`). The audio engine then gets a fresh `_transferStartTimeStamp` and a non-zero `_hostTime`, and playback works. Confirmed on `dcpext0` (HDMI through the hub) and `dcpext1` (DisplayPort).

- Rebuilding one display's link can silently break another display's working audio. At 13:05 the U2520D (`dcpext1`) was cycled, and it logged `handleStartLink Failed to get workloop` while reconnecting. The U2518D on `dcpext0` had been healthy for 13 minutes, but from 13:07 its engine showed `_hostTime=0` with an unchanged `_transferStartTimeStamp`. `dcpext0` logged nothing during the cycle. It happened again in the opposite direction at 13:16: cycling `dcpext0` repaired it, and `dcpext1`, healthy at 13:08, was stuck straight afterwards.

This suggests the fault is a race in the initial, simultaneous link bring-up rather than a hardware or cable problem: the same link works once it is set up on its own.

### Why a fix needs to come from Apple

The evidence points to the DCP coprocessor firmware and the `DCPAVFamily` / `IOAVFamily` kernel path. The DCP firmware is signed by Apple and loaded by the OS, and kernel text is locked after boot, so third parties cannot correct it. The only user-side mitigation is a private-API display power cycle, which blanks the screen, rearranges windows and may break in any release.

### Suggested fixes

- Serialise audio link start across DCPs, or retry `handleStartLink` once any in-progress HDCP negotiation completes, instead of failing.
- Propagate audio link start failure, so that `StartLink` is not recorded as successful and the HAL device is not published as usable.
- Have `DCPAVAudioDriver` detect an engine that produces no timestamps within a short interval after IO starts, and re-run link setup itself, as the display disable/enable cycle does.
- In `coreaudiod`, after a device repeatedly fails to establish a timeline, mark it not alive or surface an error, rather than blocking every client for 10 s on each attempt.

### Attachments

- sysdiagnose
- `1-hotplug-audio-link-setup.log`: kernel audio link setup at hot-plug
- `2-playback-failure-loop.log`: `coreaudiod`, kernel and NowPlaying during a failed playback
- `3-mode-switch-no-relink.log`: kernel during a mode switch, showing no audio link activity
- `4-display-cycle-repairs-audio.log`: kernel during the disable/enable repair
- `5-ioreg-DCPAVAudioDriver.txt`: IORegistry state of the three display-audio engines
- `6-system-info.txt`: OS, displays and audio devices
- `7-workaround-tool-log.txt`: probe and repair results from the workaround tool (https://github.com/juanjsebgarcia/loudstation)
- `8-cycling-one-display-breaks-another.log`: cycling `dcpext1` followed by `dcpext0`'s working audio engine dying
