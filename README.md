# Scribe

Meeting notes for macOS that never leave your Mac.

Scribe notices when you join a call, records it, transcribes it and writes notes with action items. Transcription and notes both run locally.

## Requirements

- macOS 26 or later on Apple Silicon
- [Homebrew](https://brew.sh)
- Xcode 26 or later, to compile Scribe
- About 1 GB of disk for the speech model, plus a notes model:
  - [Ollama](https://ollama.com) with any chat model you already have, or
  - the built-in engine, which downloads a 2–9 GB model depending on your RAM

## Install

```bash
brew install azeemhassni/tap/scribe
```

Homebrew builds Scribe from source on your Mac and signs it there, which takes a few minutes. Spell out the full `azeemhassni/tap/scribe` name: Homebrew refuses to load a formula from a tap it has not been told to trust, and naming it in full on an `install` is what tells it. After that, `brew upgrade` works normally.

Then put it where Spotlight and Launchpad can find it, and open it:

```bash
ln -sfn "$(brew --prefix scribe)/Scribe.app" /Applications/Scribe.app
open /Applications/Scribe.app
```

Work through the setup window. It downloads the speech model, finds Ollama or fetches a built-in notes model, and asks for microphone access.

Scribe lives in the menu bar. Turn on **Start Scribe at login** in Settings, or it can't detect meetings after a restart.

Updates come from `brew upgrade scribe`. Because each build is signed on your own Mac and macOS ties microphone access to the signature, an upgrade asks for microphone access again.

## How it works

- **Detection.** A meeting is a call app using the microphone (Zoom, Teams, Slack, FaceTime and others), a browser using the microphone with a meeting tab open (Meet, Teams, Zoom, Whereby and others), or any app using the microphone and speakers at once. Scribe asks before recording; Settings can switch this to automatic.
- **Recording.** Your microphone and the call audio are recorded separately, so the transcript knows what you said and what everyone else said.
- **Transcription.** whisper.cpp with Whisper large-v3-turbo. The language is detected per segment. Hindi and Urdu are written in the script you choose in Settings.
- **Notes.** A summary, key points, decisions, action items and open questions. Written in the meeting's own language by default, or in a language you pick in Settings, whatever was spoken. Action items link back to the line where they were said.
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
| `--setup-check` | Show the notes models setup would offer and which one it picks |
| `--transcribe-file <audio>` | Run an audio file through transcription and notes |
| `--retry-notes` | Retry notes for meetings where they failed |
| `--setup-local` | Install the built-in notes engine |
| `--relink` | Recompute action item links |

## Release

```bash
scripts/release.sh 0.1.0
```

Builds the version to prove it compiles, tags it, publishes a GitHub release with the commit messages since the last tag as its notes, and points the formula in [azeemhassni/homebrew-tap](https://github.com/azeemhassni/homebrew-tap) at the new tag.

Scribe ships as source, so a release has no binary to notarize and nothing to sign for Sparkle. Every copy is compiled and signed on the Mac it runs on, which is also why Homebrew installs have Sparkle's own update check turned off.

The script expects a checkout of the tap next to this one, at `~/Code/homebrew-tap`, or wherever `SCRIBE_TAP` points.

## License

[GPL-3.0](LICENSE)
