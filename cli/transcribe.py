#!/usr/bin/env python3
"""
VibeTranscribe - Quick prototype
Transcribe audio in any language to English
"""

import sys
import argparse
from transformers import WhisperProcessor, WhisperForConditionalGeneration
import librosa

def transcribe_audio(audio_path, model_size="base", translate=True):
    """
    Transcribe audio file using Whisper
    
    Args:
        audio_path: Path to audio file
        model_size: Whisper model size (tiny, base, small, medium, large-v2)
        translate: If True, translate to English. If False, transcribe in original language
    """
    print(f"🎤 Loading Whisper {model_size} model...")
    
    # Load model and processor
    model_name = f"openai/whisper-{model_size}"
    processor = WhisperProcessor.from_pretrained(model_name)
    model = WhisperForConditionalGeneration.from_pretrained(model_name)
    
    print(f"📂 Loading audio: {audio_path}")
    
    # Load audio file
    audio_array, sampling_rate = librosa.load(audio_path, sr=16000)
    
    # Process audio
    input_features = processor(
        audio_array, 
        sampling_rate=sampling_rate, 
        return_tensors="pt"
    ).input_features
    
    # Set task
    task = "translate" if translate else "transcribe"
    forced_decoder_ids = processor.get_decoder_prompt_ids(language=None, task=task)
    
    print(f"🔄 Processing (task: {task})...")
    
    # Generate transcription
    predicted_ids = model.generate(input_features, forced_decoder_ids=forced_decoder_ids)
    
    # Decode
    transcription = processor.batch_decode(predicted_ids, skip_special_tokens=True)[0]
    
    return transcription


def main():
    parser = argparse.ArgumentParser(description="VibeTranscribe - Transcribe audio to English")
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("--model", default="base", choices=["tiny", "base", "small", "medium", "large-v2"],
                        help="Whisper model size (default: base)")
    parser.add_argument("--no-translate", action="store_true", 
                        help="Only transcribe, don't translate to English")
    
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
        
    except FileNotFoundError:
        print(f"❌ Error: Audio file '{args.audio_file}' not found")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
