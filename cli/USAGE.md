# VibeTranscribe CLI - Complete Usage Guide

## What You Have Now ✅

A fully working CLI tool that:
1. **Transcribes** audio in ANY language
2. **Translates** to English automatically  
3. **Summarizes** with AI (optional, requires OpenAI API key)

---

## Quick Test Results

### Your Urdu Audio Sample:

**Transcription:**
> "I am trying to monitor my voice and I can see how good my recording is. At this time, I can hear my voice live. I am also checking the distance. I am also checking the distance. When I keep my face close to my face, I it makes a very good sound."

---

## Usage

### Basic (Transcription Only)
```bash
cd cli
source venv/bin/activate
python vibetranscribe.py audio.mp3 --no-summarize
```

### With AI Summary (requires OpenAI API key)
```bash
# Set your API key first
export OPENAI_API_KEY="sk-your-key-here"

# Run with summary
python vibetranscribe.py audio.mp3 --summary short
```

### All Options
```bash
python vibetranscribe.py audio.mp3 \
  --model small \              # Model size: tiny, base, small, medium, large-v2
  --summary medium \           # Summary length: short, medium, long
  --format md \                # Output format: text, md, markdown
  --output result.md           # Save to file
```

---

## To Enable Summarization

You need an OpenAI API key. Get one at: https://platform.openai.com/api-keys

Then set it:
```bash
export OPENAI_API_KEY="sk-your-key-here"
```

Or pass it directly:
```bash
python vibetranscribe.py audio.mp3 --api-key "sk-your-key-here"
```

---

## What Summarization Adds

When enabled, you get:
- **Summary**: Clean, concise overview
- **Key Points**: Bullet list of main ideas
- **Action Items**: Extracted tasks (if any mentioned)

Example output:
```
SUMMARY:
User testing microphone quality and monitoring live audio feedback while checking optimal recording distance.

KEY POINTS:
• Testing voice monitoring system
• Checking recording quality in real-time  
• Experimenting with microphone distance
• Achieving better sound quality with closer positioning

ACTION ITEMS:
None
```

---

## Next Steps

1. **Get OpenAI API key** to enable summarization
2. **Test with more audio samples**
3. **Try different summary lengths** (short/medium/long)
4. **Export results** to markdown files
