#!/usr/bin/env python3
"""
Quick test script to verify Whisper installation
"""

print("Testing imports...")

try:
    import transformers
    print(f"✅ transformers version: {transformers.__version__}")
except ImportError as e:
    print(f"❌ transformers: {e}")

try:
    import torch
    print(f"✅ torch version: {torch.__version__}")
except ImportError as e:
    print(f"❌ torch: {e}")

try:
    import librosa
    print(f"✅ librosa version: {librosa.__version__}")
except ImportError as e:
    print(f"❌ librosa: {e}")

print("\n✨ All dependencies ready!")
print("\nTo test transcription, run:")
print("  python transcribe.py <audio-file>")
