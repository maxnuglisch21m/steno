# Third-party licenses

| Component | License | File |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) — on-device ASR (Parakeet) and offline diarization (pyannote) | Apache-2.0 | `FluidAudio-LICENSE.txt` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) — in-app updates | MIT | `Sparkle-LICENSE.txt` |
| [AudioCap](https://github.com/insidegui/AudioCap) — Core Audio process taps, adapted | BSD-2-Clause | `AudioCap-LICENSE.txt` |

## AudioCap

No AudioCap code is vendored; its approach is. `Sources/Steno/Audio/ProcessTapRecorder.swift`
and `Sources/Steno/Audio/CoreAudioObject.swift` follow `ProcessTap.swift` and
`CoreAudioUtils.swift` from that project: the `CATapDescription` →
`AudioHardwareCreateProcessTap` sequence, the aggregate-device dictionary
(`kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`,
`kAudioAggregateDeviceIsPrivateKey`), the `AudioDeviceCreateIOProcIDWithBlock` call,
the order things are destroyed in, and the property-reading helpers.

What Steno does differently is the part §3a needs: the microphone is a second member of
the same aggregate device, so both channels share one clock and one callback; the tap
does not auto-start, so the callback keeps running while the tapped app is silent; and
the callback itself is real-time safe, writing into a lock-free ring buffer that a
separate thread drains into the WAV file.
