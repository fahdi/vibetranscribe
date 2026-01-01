# VibeTrans cribe CLI

> Transcribe audio in **any language** → Get clean **English text** + **AI-powered summaries**

Perfect for non-native English speakers who think in one language but work in English.

---

## 🎯 Features

✅ **Multilingual Support** - Auto-detects 96+ languages  
✅ **English Translation** - Always translates to English  
✅ **AI Summarization** - Extract key points and action items  
✅ **Local-First** - Runs on your machine (no cloud costs for transcription)  
✅ **Fast** - Apple Silicon GPU acceleration  
✅ **Open Source** - MIT License  

---

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/vibetranscribe.git
cd vibetranscribe/cli

# Create virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

### Basic Usage

```bash
# Transcribe + translate to English
python vibetranscribe.py audio.mp3 --no-summarize

# With AI summary (requires OpenAI API key)
export OPENAI_API_KEY="sk-your-key-here"
python vibetranscribe.py audio.mp3 --summary short
```

---

## 📖 Examples

### Example 1: Urdu → English
```bash
python vibetranscribe.py recording.wav --no-summarize
```

**Result:**
> "I am trying to monitor my voice and I can see how good my recording is..."

### Example 2: Spanish Meeting → Summary
```bash
python vibetranscribe.py meeting.m4a --summary medium --format md --output result.md
```

---

## 🛠️ Usage

### Command Options

```bash
python vibetranscribe.py <audio_file> [OPTIONS]
```

**Required:**
- `audio_file` - Path to audio file (mp3, wav, m4a, ogg)

**Options:**
- `--model {tiny,base,small,medium,large-v2}` - Whisper model size (default: small)
- `--summary {short,medium,long}` - Summary length (default: short)
- `--no-summarize` - Skip AI summary, only transcribe
- `--format {text,md,markdown}` - Output format (default: text)
- `--output FILE` - Save to file
- `--api-key KEY` - OpenAI API key (or set `OPENAI_API_KEY` env var)

### Model Sizes

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| tiny | 151 MB | ⚡⚡⚡ | ⭐⭐ |
| base | 290 MB | ⚡⚡ | ⭐⭐⭐ |
| **small** | 967 MB | ⚡ | ⭐⭐⭐⭐ (recommended) |
| medium | 1.5 GB | 🐌 | ⭐⭐⭐⭐⭐ |
| large-v2 | 6 GB | 🐌🐌 | ⭐⭐⭐⭐⭐ |

---

## 🧪 Testing

```bash
# Install test dependencies
pip install -r requirements-test.txt

# Run tests (fast, no audio processing)
pytest -v -m "not slow"

# Run integration tests (with real audio)
pytest -v
```

**Test Results:** ✅ 19 tests, all passing  
**Coverage:** 92% on core summarization module

See [cli/TESTING.md](cli/TESTING.md) for details.

---

## 📁 Project Structure

```
cli/
├── vibetranscribe.py       # Main CLI tool ⭐
├── summarize.py            # AI summarization
├── generate_test_samples.py # Test audio generator
├── test_vibetranscribe.py  # Test suite
├── requirements.txt        # Dependencies
├── TESTING.md             # Test documentation
└── USAGE.md               # Detailed usage guide

docs/
└── PRD.md                 # Product requirements
```

---

## 💡 AI Summarization

To enable AI-powered summaries:

1. Get an OpenAI API key: https://platform.openai.com/api-keys
2. Set environment variable:
   ```bash
   export OPENAI_API_KEY="sk-your-key-here"
   ```
3. Run with summary:
   ```bash
   python vibetranscribe.py audio.mp3 --summary short
   ```

**What you get:**
- **Summary**: Clean, concise overview
- **Key Points**: Bullet list of main ideas  
- **Action Items**: Extracted tasks (if mentioned)

---

## 🌍 Supported Languages

Auto-detects and translates from 96+ languages including:

English, Spanish, French, German, Italian, Portuguese, Dutch, Russian, Arabic, Chinese, Japanese, Korean, Hindi, Urdu, Bengali, Turkish, Polish, Ukrainian, Vietnamese, Thai, and many more...

---

## 🤝 Contributing

Contributions welcome! Please feel free to submit a Pull Request.

---

## 📄 License

MIT License - see LICENSE file for details

---

## 🙏 Credits

- Built with [OpenAI Whisper](https://github.com/openai/whisper)
- Powered by [HuggingFace Transformers](https://huggingface.co/transformers/)
- Summarization by [OpenAI GPT-4](https://openai.com)

---

**Built by [@isupercoder](https://github.com/isupercoder)**
