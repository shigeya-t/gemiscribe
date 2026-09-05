# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

GemiScribe: a macOS (15+) SwiftUI sample app for the Gemini Transcribe Live model
(`gemini-3.5-transcribe-live`). It streams system audio and/or the microphone to the Live API over a
WebSocket, assembles the transcript into sentence-aligned timestamped blocks, and translates blocks
through `generateContent`. User-facing docs: `README.md` (Japanese), `README.en.md` (English). The
"仕組み / How it works" section there is the authoritative description of the Live API behaviours the
code works around; keep it in sync when changing `SessionCoordinator`, `BlockAssembler` or
`BlockTimestamper`.

## Commands

```bash
# Build (Debug). Output goes to build/Debug/GemiScribe.app; SYMROOT/OBJROOT are set in the project,
# so Xcode ⌘R lands in the same place.
xcodebuild -project GemiScribe.xcodeproj -scheme GemiScribe -configuration Debug build

# All tests
xcodebuild test -project GemiScribe.xcodeproj -scheme GemiScribe -destination 'platform=macOS'

# One test class / one test
xcodebuild test -project GemiScribe.xcodeproj -scheme GemiScribe -destination 'platform=macOS' \
  -only-testing:GemiScribeTests/SeamRepairTests
xcodebuild test -project GemiScribe.xcodeproj -scheme GemiScribe -destination 'platform=macOS' \
  -only-testing:GemiScribeTests/BlockMergingTests/testSentencesSplitAcrossTurnsAreRejoined

# Run with every Live API frame logged to the unified log
open build/Debug/GemiScribe.app --args --debug
/usr/bin/log show --predicate 'subsystem == "jp.namio.GemiScribe"' --last 30m --style compact --info
```

Notes:
- The Xcode project uses file-system-synchronized groups: new `.swift` files under `GemiScribe/` or
  `GemiScribeTests/` are picked up without editing the pbxproj.
- Use `/usr/bin/log` explicitly; a shell alias for `log` breaks the `--predicate` form.
- After a rebuild the user must relaunch the app; a running process keeps the old dylib. When a log
  looks like an old build, check `ps -o lstart -p $(pgrep -x GemiScribe)` against the dylib mtime.
- Log lines are truncated by the unified log at roughly 1 KB, and SMART-mode finals contain `\n` and
  `\"` escapes; when parsing `log show` output, match `inputTranscription` loosely rather than as
  strict JSON.
- Signing is manual with `DEVELOPMENT_TEAM`; on another Mac change it in build settings.
- Debug logging is on when the Settings toggle is set or `--debug` is passed; `--debug` forces it.

## Architecture

Audio → session → transcript → translation, all wired together in `App/AppState.swift` (`@MainActor`,
`@Observable`). Everything below the wiring is either a plain struct/class with unit tests or an actor-free
class that hops to the main queue.

**Audio (`Audio/`)** — `AudioSourceManager` owns `SystemAudioCapture` (ScreenCaptureKit, needs Screen
Recording permission), `MicrophoneCapture` (AVCaptureSession, deliberately not `AVAudioEngine`), and
`AudioMixer`. The mixer pulls from ring buffers on a 100 ms timer and emits 16 kHz mono PCM16 chunks; it
is also the recording's clock (`elapsedSeconds` = chunks emitted ÷ 10). It keeps a 2-chunk cushion so
capture jitter never splices silence into speech, and inserts silence only after 300 ms of real
starvation. `SpeechActivityDetector` is a local RMS VAD used for heartbeat stats and as a timestamp
fallback, not as the primary segmenter.

**Session (`Gemini/`)** — `LiveTranscriptionClient` is one WebSocket to `BidiGenerateContent`;
`LiveProtocol` holds the wire types (decoding is all-optional on purpose). `SessionCoordinator` owns the
client lifecycle and is where most of the API-specific logic lives:
- Forces turn boundaries with `audioStreamEnd` because the server never finalizes continuous speech on
  its own. `TurnBoundaryPolicy` (pure, tested) decides when: ≥8 s and the partial ends on sentence
  punctuation, or 25 s; resend once at 3 s, replace the connection at 15 s. Nothing is forced while no
  turn is open (no partial since the last final).
- Holds outgoing audio for 0.5 s after each forced boundary, then pads the stream with 0.4 s of silence
  plus a 0.2 s replay of the audio just before the boundary. The server discards the audio that arrives
  while its VAD looks for a speech onset (measured: 0.32 s with no padding, 0.16 s with silence alone),
  and the padding is what takes that loss instead of the next sentence's first words. Padding advances
  the server's offsets, so `injectedAudioSec` is subtracted when mapping `voiceActivity` back to
  recording time.
- `InterimCleaner` strips the previous segment's words the server repeats at the head of new partials
  (fuzzy prefix match). `SeamRepair` does the two seam fixes on finals: it puts back a head SMART mode
  dropped but the last partial still had (skipping pure fillers, stutters and anything the previous
  block already ends on), and it trims leading words the previous block already ends on, which is what
  the replayed padding occasionally produces.
- Rotates connections before the ~10-minute cap: standby opened at 8m30s (or on `goAway`), promoted only
  when no turn/segment is open, with the last 0.3 s of audio replayed to the new socket. Finals are
  accepted only from the current or a retiring client. On an unexpected close the open partial is
  salvaged as a block (`onSalvagePartial`) and the connection reopened.
- `sessionResumption` is requested but this model never issues handles; every connection is a new
  session.
- Heartbeat every 10 s (`heartbeat mode=… chunksSent=… sendBacklog=… interims=… finals=…
  sinceServerMsg=… turnOpen=… underruns=…`) is the first thing to read when diagnosing a bad recording.

**Transcript (`Model/`)** — `BlockTimestamper` turns server `voiceActivity` offsets (per-connection,
anchored on the first chunk's clock time) into recording time, falling back to local spans, then to the
clock. `BlockAssembler` (pure, heavily tested) merges a turn into the previous block when that block does
not end a sentence and the gap is under 3 s (no character limit), detaches the unfinished tail of a final
into its own open block, splits blocks over 60 s on sentence boundaries, and flattens SMART paragraph
breaks. `TranscriptStore` is the observable façade over it. Block identity is preserved across merges so
in-flight translations are discarded rather than misapplied.

**Translation (`Gemini/Translation*`)** — `TranslationCoordinator` batches settled blocks (debounce 1.2 s,
≥3 s between requests, 429 pauses the whole queue for the requested delay). `TranslationService` sends a
numbered list with a JSON-array response schema. Blocks are translated on their own; passing neighbouring
context was tried and leaked into the output. `AppState.scheduleTranslations` only translates the newest
block once it is settled (ends a sentence and ≥20 chars) or after the merge window, and never a short
fragment on its own.

**Settings/Localization** — `AppSettings` persists to UserDefaults (API key in Keychain via
`KeychainStore`). UI strings live in `Localization/Strings.swift` as `LocKey` tables for `ja` and `en`;
every key must exist in both (a test checks). The recognition language and SMART/VERBATIM mode are part
of the Live setup message, so they only take effect on the next recording.

## Working conventions seen in this repo

- Comments explain the observed API behaviour that motivated a rule, with the concrete example from a
  log. Keep that style; the numbers (8 s, 25 s, 0.5 s hold, 0.4 s silence, 0.2 s replay, 60 s) are all
  evidence-based tunings measured from `voiceActivity` offsets, so cite the log when changing them.
- Server behaviour is verified from `log show` output, not assumed. Sessions from earlier today are
  parsed with a small Python script in the scratchpad; write a fresh one rather than trusting grep on
  `← FINAL` lines.
- Tests replay real turns/partials captured from logs (see `BlockMergingTests`, `TurnBoundaryTests`).
  When fixing a seam or merge bug, add the exact strings from the log as a test case.
