#!/usr/bin/env python3
"""
VibeTranscribe v2 - Improved with pipeline API
Transcribe audio in any language to English
"""

import sys
import argparse
from transformers import pipeline
import torch

def transcribe_audio(audio_path, model_size="small", translate=True):
    """
    Transcribe audio file using Whisper with improved pipeline
    
    Args:
        audio_path: Path to audio file
        model_size: Whisper model size (tiny, base, small, medium, large-v2)
        translate: If True, translate to English. If False, transcribe in original language
    """
    print(f"🎤 Loading Whisper {model_size} model with pipeline...")
    
    # Check if MPS (Apple Silicon) is available
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"🔧 Using device: {device}")
    
    # Create pipeline
    model_name = f"openai/whisper-{model_size}"
    
    task = "translate" if translate else "transcribe"
    
    pipe = pipeline(
        "automatic-speech-recognition",
        model=model_name,
        device=device,
        chunk_length_s=30,  # Process in 30 second chunks
        return_timestamps=False
    )
    
    print(f"📂 Loading audio: {audio_path}")
    print(f"🔄 Processing (task: {task})...")
    
    # Process audio
    result = pipe(
        audio_path,
        generate_kwargs={
            "task": task,
            "language": None,  # Auto-detect
        }
    )
    
    return result["text"].strip()


def main():
    parser = argparse.ArgumentParser(description="VibeTranscribe v2 - Transcribe audio to English")
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("--model", default="small", choices=["tiny", "base", "small", "medium", "large-v2"],
                        help="Whisper model size (default: small)")
    parser.add_argument("--no-translate", action="store_true", 
                        help="Only transcribe, don't translate to English")
    parser.add_argument("--output", "-o", help="Output file path (optional)")
    
    args = parser.parse_args()
    
    try:
        result = transcribe_audio(
            args.audio_file, 
            model_size=args.model,
            translate=not args.no_translate
        )
        
        print("\n" + "="*50)
        print("📝 TRANSCRIPTION:")
        print("="*50)
        print(result)
        print("="*50 + "\n")
        
        # Save to file if specified
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(result)
            print(f"💾 Saved to: {args.output}\n")
        
    except FileNotFoundError:
        print(f"❌ Error: Audio file '{args.audio_file}' not found")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
