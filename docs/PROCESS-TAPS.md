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
every build, so both permissions must be re-approved after each rebuild.

`scripts/create-signing-identity.sh` creates a local self-signed code-signing
certificate so the identity stays stable and the permissions are granted once.
`package-app.sh` picks it up automatically when present. Two macOS quirks make
the script less obvious than it looks: the certificate needs
`extendedKeyUsage=codeSigning` or codesign never offers it, and the PKCS#12
bundle must be written with `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
-macalg sha1`, because Security framework rejects current OpenSSL defaults
with a misleading "MAC verification failed (wrong password?)".

## A coreaudiod restart silently kills the agent

Reinstalling the driver restarts coreaudiod, which invalidates every
AudioObjectID and IOProc the agent holds. The failure is quiet: the IOProcs
keep firing on schedule with correctly-shaped buffers, and the ring backlog
stays healthy — the buffers are just silent. Watching for audio to *stop
flowing* therefore does not detect it.

What does detect it: CoreAudio hands out fresh object IDs after the restart,
so re-resolving the device UID and comparing against the ID the relay was
built on is an exact signal. `MixerController` listens for
`kAudioHardwarePropertyDevices` changes and rebuilds when the IDs no longer
match. Devices reappear slightly after coreaudiod returns, so the first
restart attempt can find no output device at all and the retry matters.

## Verified end to end

`scripts/verify-per-app-volume.sh` measures peak levels at several tap
volumes against a 0.3-amplitude tone:

| tap volume | tapmix | fallback |
|---|---|---|
| 100% | 0.3000 | 0.0000 |
| 50%  | 0.1500 | 0.0000 |
| 20%  | 0.0600 | 0.0000 |
| 0%   | 0.0000 | 0.0000 |

## Output must go through a HAL output unit, not a raw IOProc

The pipeline runs at a fixed 48kHz. Writing those frames straight into a device
running at a different rate plays them at the wrong speed: at 44.1kHz they run
~8.8% slow, which is about 1.5 semitones flat and very audible on speech. Most
Bluetooth headsets only do 44.1kHz, so the built-in speakers (which do 48kHz)
hide this completely.

Setting `kAudioDevicePropertyNominalSampleRate` to 48000 is still worth trying,
but it cannot be relied on. Output therefore goes through a
`kAudioUnitSubType_HALOutput` unit with its *input* format fixed at 48kHz
stereo Float32: the unit resamples and remaps channels to whatever the device
needs. That also removes the need to reject devices that are not interleaved
Float32 stereo.

`MixerController` logs each path's measured frame rate, so a rate mismatch
shows up as a number other than ~48000 rather than as a sound someone has to
notice.

## A virtual device must report its downstream latency

Apps read `kAudioDevicePropertyLatency` from the output device to line video up
with audio. A virtual device is only the front door — the sound actually leaves
through whatever the mixer plays into, and a Bluetooth headset can be 200ms+
behind on its own (RY-WH02 reports 10284 frames at 44.1kHz = 233ms).

Reporting 0, as a passthrough device naturally does, makes every video player
believe audio is instantaneous, so it does not delay the picture and the audio
visibly trails it. Playing to the same headset directly has no such problem,
because then the player sees the real figure.

The mixer therefore measures its output device's latency, converts it to the
pipeline's frame rate, adds its own buffering, and publishes the total to the
driver, which reports it as the device's latency.

Getting the value *into* the driver takes some care:

- The HAL rejects client writes to `kAudioDevicePropertyLatency` with `'nope'`
  before they reach the driver, so a custom selector is required.
- The HAL only forwards custom selectors a driver has declared through
  `kAudioObjectPropertyCustomPropertyInfoList`; without that, everything else
  is `'who?'`, including `AudioObjectHasProperty`.
- Custom properties carry only `CFString` or `CFPropertyList`, so a frame count
  travels as a `CFNumber`, not a `UInt32`.

## Latency picked up during a transient is permanent unless it is dropped

Capture starts as soon as the device opens, while the output unit only begins
pulling once it is ready. Everything queued in between is audio nobody has
heard, and because producer and consumer then run at the same rate, nothing
drains it — measured 105ms after a device switch and 403ms after one Bluetooth
start, both staying put.

The render path drops that backlog on its first callback after IO starts, and
sheds a few frames per callback whenever the queue sits above target. Tune it
against the underrun counter rather than by ear: trimming too hard turns
latency into dropouts, which are worse.

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
