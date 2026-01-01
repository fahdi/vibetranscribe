# VibeTranscribe CLI Prototype

## Quick Start

```bash
# Install dependencies (one-time setup)
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Run transcription
python transcribe.py <audio-file>

# Examples:
python transcribe.py meeting.mp3
python transcribe.py lecture.m4a --model tiny
python transcribe.py french_audio.wav --no-translate
```

## Options

- `--model` - Choose model size: `tiny`, `base`, `small`, `medium`, `large-v2` (default: base)
- `--no-translate` - Only transcribe, don't translate to English

## How it works

1. Loads Whisper model from HuggingFace
2. Processes audio file
3. Auto-detects language
4. Transcribes and translates to English (or just transcribes)

## Model sizes & performance

- **tiny** (~39M params) - Fastest, less accurate
- **base** (~74M params) - Good balance for testing ✅
- **small** (~244M params) - Better quality
- **medium** (~769M params) - High quality
- **large-v2** (~1550M params) - Best quality

First run will download the model (~150MB for base, ~3GB for large-v2).
