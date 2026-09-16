# Scribe

Meeting notes for macOS that never leave your Mac.

Scribe notices when you join a call, records it, transcribes it and writes notes with action items. Transcription and notes both run locally.

## Requirements

- macOS 14.4 or later on Apple Silicon
- [Homebrew](https://brew.sh), for whisper.cpp
- About 1 GB of disk for the speech model, plus a notes model:
  - [Ollama](https://ollama.com) with `gpt-oss:20b` (13 GB), if you have it, or
  - the built-in engine, which downloads a 2–9 GB model depending on your RAM

## Install

1. Download `Scribe.zip` from [Releases](https://github.com/azeemhassni/scribe/releases/latest).
2. Move `Scribe.app` to Applications and open it.
3. Follow the setup window. It installs whisper.cpp, downloads models and asks for microphone access.

Scribe lives in the menu bar. Turn on **Start Scribe at login** in Settings, or it can't detect meetings after a restart.

## How it works

- **Detection.** A meeting is a call app using the microphone (Zoom, Teams, Slack, FaceTime and others), a browser using the microphone with a meeting tab open (Meet, Teams, Zoom, Whereby and others), or any app using the microphone and speakers at once. Scribe asks before recording; Settings can switch this to automatic.
- **Recording.** Your microphone and the call audio are recorded separately, so the transcript knows what you said and what everyone else said.
- **Transcription.** whisper.cpp with Whisper large-v3-turbo. The language is detected per segment. Hindi and Urdu are written in the script you choose in Settings.
- **Notes.** A summary, key points, decisions, action items and open questions, written in the meeting's language. Action items link back to the line where they were said.
- **Library.** Meetings, a searchable transcript, playback from any line, and every action item across meetings in one list. Meetings can also be exported as Markdown to a folder, such as an Obsidian vault.

If notes can't be written, the transcript is still saved and the meeting has a Retry button.

## Privacy

Audio, transcripts and notes stay on your Mac in `~/Library/Application Support/Scribe`. The notes model is reached over `127.0.0.1` only.

Scribe connects to the internet to download models and the built-in engine, from Hugging Face and GitHub. If you export meetings to a folder that syncs, such as iCloud Drive, that folder's contents sync.

## Build

```bash
scripts/bundle.sh
cp -R build/Scribe.app /Applications/
```

To change the icon, edit `Resources/AppIcon.svg` and run `scripts/icon.sh` (needs `brew install librsvg`).

The build is signed with the first Developer ID identity in your keychain. Without one it is signed ad-hoc, and macOS asks for microphone access again after every rebuild.

Check an install:

```bash
/Applications/Scribe.app/Contents/MacOS/Scribe --doctor
```

Other command-line modes:

| Flag | Does |
|---|---|
| `--probe-detection [seconds]` | Show which apps are using audio and whether it counts as a meeting |
| `--transcribe-file <audio>` | Run an audio file through transcription and notes |
| `--retry-notes` | Retry notes for meetings where they failed |
| `--setup-local` | Install the built-in notes engine |
| `--relink` | Recompute action item links |

## Release

```bash
scripts/release.sh 0.1.0
```

Builds for Apple Silicon, notarizes, tags and publishes a GitHub release with `Scribe.zip`. It needs a notarytool keychain profile; see the top of the script.

## License

[GPL-3.0](LICENSE)
