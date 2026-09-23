# Core Audio process taps: what actually works

Findings verified empirically on this machine (macOS 15.8, x86_64, Command Line
Tools SDK 15.5). Apple's documentation is thin here and the failure modes are
silent, so these are recorded as ground truth for the project.

## The API is usable without special entitlements

`AudioHardwareCreateProcessTap` returns `noErr` from a plain unsandboxed,
ad-hoc-signed binary. No Apple-granted entitlement is needed. Enumerating
processes via `kAudioHardwarePropertyProcessObjectList` likewise works, and
exposes `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` and
`kAudioProcessPropertyIsRunningOutput`.

## One AudioBuffer per sub-tap

An aggregate device built with N process taps delivers `mNumberBuffers == N`
in its input IOProc, one buffer per sub-tap, in sub-tap-list order. Verified
with 3 simultaneous taps: 3 buffers of 2 channels each.

This is what lets a per-app gain be applied by buffer index. `TapManager`
still reads the count back from the device and warns on a mismatch rather
than trusting the assumption.

## Two separate permissions are needed, and both fail silently

Reading the Attenuator Device's **input stream** is microphone-class access as
far as TCC is concerned, even though the device is virtual and has no
microphone. That is a *different* permission from the one the taps need:

| What | TCC service | Info.plist key | System Settings pane |
|---|---|---|---|
| Reading the virtual device's input | `kTCCServiceMicrophone` | `NSMicrophoneUsageDescription` | Microphone |
| Per-app process taps | `kTCCServiceAudioCapture` | `NSAudioCaptureUsageDescription` | Screen & System Audio Recording |

Missing the microphone key produces exactly the same silent failure as the
audio-capture one:

```
Refusing authorization request for service kTCCServiceMicrophone and subject
Sub:{com.audioattenuator.agent} ... without NSMicrophoneUsageDescription key
```

Terminals usually already hold the microphone permission, which is why a CLI
build can appear to work perfectly while the packaged agent gets nothing but
zeros — the terminal's grant was doing the work.

**A grant only takes effect for a process started after it.** An agent that
was already running when permission was granted keeps failing (observed as
`AudioDeviceStart` returning 268451843) until it is restarted.

Because opening a device blocks until the prompt is answered, the audio setup
must not run inline in `applicationDidFinishLaunching` — doing so leaves the
menu bar icon missing and the app looking hung while the prompt waits.

## The silent failure: TCC attribution

**A tap can be created successfully and still deliver nothing but zeros.**
There is no error code for this — `AudioHardwareCreateProcessTap` succeeds,
the aggregate device is created, the IOProc fires at the correct rate with
correctly-shaped buffers, and every sample is 0.

The cause is the `kTCCServiceAudioCapture` privacy permission. Two separate
things have to be true:

### 1. The app needs a bundle identity and a usage description

A bare CLI binary has no identity TCC can attribute a grant to. The agent must
be a real `.app` with:

- `CFBundleIdentifier` (`com.audioattenuator.agent`)
- `NSAudioCaptureUsageDescription` in `Info.plist`
- a code signature (ad-hoc is enough for local development, but the grant is
  keyed to the code identity and is invalidated on rebuild)

`scripts/package-app.sh` produces this.

### 2. The app must be its own TCC "responsible process"

This is the part that cost the most time to find. TCC does not check the
permission of the process calling the API — it checks the *responsible*
process, which for anything started from a terminal is the terminal itself.

Running the agent from a shell produces this in `log stream --predicate
'subsystem == "com.apple.TCC"'`:

```
AUTHREQ_ATTRIBUTION: responsible={identifier=com.mitchellh.ghostty ...},
                     accessing={identifier=com.audioattenuator.agent ...}
AUTHREQ_PROMPTING: service=kTCCServiceAudioCapture, subject=Sub:{com.mitchellh.ghostty}
Refusing authorization request ... without NSAudioCaptureUsageDescription key
AUTHREQ_RESULT: authValue=0, authReason=8
```

The app is correctly identified as *accessing*, but the permission is looked
up against the terminal, which has no audio-capture usage string — so macOS
refuses to even show a prompt, and the taps return silence. Granting
"Attenuator" the permission in System Settings does not help, because the
question being asked is about the terminal.

Launching via `open -a` does not fix this either: LaunchServices still
attributes responsibility to the calling terminal.

**Launching through launchd does fix it.** A launchd-started agent is its own
responsible process, so the grant applies. This is why
`launchd/com.audioattenuator.agent.plist` is not merely an autostart
convenience — it is load-bearing for the taps to work at all.

### Granting the permission

System Settings → Privacy & Security → Screen & System Audio Recording →
enable Attenuator. (`authValue`: 0 = denied, 1 = unknown/not yet granted,
2 = allowed.)

## Muting works as documented

With `muteBehavior = .muted`, a tapped app's audio stops reaching its normal
output route the instant the tap exists. Measured with a 0.3-amplitude tone:
the fallback path (reading the Attenuator Device) drops to exactly 0.0000
while the tap path carries the audio. No double-playback, no gap.

## Ad-hoc signing invalidates grants on every rebuild

TCC keys a grant to the code identity (cdhash). An ad-hoc signature changes on
every build, so both permissions must be re-approved after each rebuild during
development. A Developer ID signature would make the grants stable.

## Verified end to end

`scripts/verify-per-app-volume.sh` measures peak levels at several tap
volumes against a 0.3-amplitude tone:

| tap volume | tapmix | fallback |
|---|---|---|
| 100% | 0.3000 | 0.0000 |
| 50%  | 0.1500 | 0.0000 |
| 20%  | 0.0600 | 0.0000 |
| 0%   | 0.0000 | 0.0000 |

## Gotchas when testing

- The audio source must be a **single stable process**. A tap binds to
  specific process objects, so a source that relaunches (`afplay` in a loop)
  leaves each new instance untapped and makes results look like the mute is
  leaking.
- Browsers play audio from helper/GPU processes that share the parent's
  bundle ID. `ProcessRegistry.resolve` returns *all* matching processes and
  puts them in one tap so they share a gain; tapping only the first would
  miss the audio.
- `timeout` does not exist on macOS — test scripts use the agent's own
  `--duration` plus a background watchdog.
