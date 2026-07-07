# Phase-0 spikes (throwaway de-risking)

These are small, throwaway programs that prove one risky seam each before Phase-1 code is written.
They are **not** part of the `swift build`/`swift test` machine gate (they need hardware, TCC grants,
or a running SFU). Each maps to a row in `TESTING.md`.

| Spike | Proves | Gate |
|---|---|---|
| `EncodeLoopbackSpike/` | `SCStream` → VT low-latency H.264 encode → decode → `AVSampleBufferDisplayLayer` render on ONE Mac. | machine-gateable (single device) — TESTING.md Tier-1 spikes |
| `InjectionSpike/` | `CGEvent` injection into a target window on a Dev-ID non-sandboxed build with the `kTCCServicePostEvent` grant, incl. tagged-event local-override. | machine-gateable (single device, requires the grant) |
| `SFULoadSpike/` | `livekit-server --dev` bring-up, 2-window publish at 3–5 Mbps, 9-subscriber load, uplink/encode/glass-to-glass measurement → feeds `AdmissionController` thresholds. | hardware (TESTING.md H2/H3) |
| `LegibilityCorpus/` | Codec A/B: fixed screen-text corpus, fixed-QP ladder encode, OCR character-error-rate scorer → the D5 VP9-vs-H.264 decision gate. | hardware (TESTING.md H4) |

**Why they aren't fleshed out yet:** they exercise exactly the APIs the build spec forbids
implementing from memory (VideoToolbox low-latency, ScreenCaptureKit, CGEvent injection) and cannot be
verified in this environment without paired hardware / TCC grants. They are written as the FIRST code
of Phase 0 on real hardware, per the run-book. Writing unverifiable framework code here would risk the
"never fabricate verified" rule. The seams they'll build against already exist and are tested:
`AdmissionController`, `CodecSelector`, `VTLowLatencyH264Encoder` (wrapper stub), `EventInjector`
(wrapper stub).
