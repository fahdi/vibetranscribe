#!/usr/bin/env python3
"""
StenoDrop - Complete CLI
Transcribe audio in any language → English transcription + AI summary
"""

import sys
import argparse
from transformers import pipeline
import torch
from summarize import summarize_text, format_summary_output

def transcribe_audio(audio_path, model_size="small"):
    """
    Transcribe audio file using Whisper
    """
    print(f"🎤 Loading Whisper {model_size} model...")
    
    # Check if MPS (Apple Silicon) is available
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    
    # Create pipeline
    model_name = f"openai/whisper-{model_size}"
    
    pipe = pipeline(
        "automatic-speech-recognition",
        model=model_name,
        device=device,
        chunk_length_s=30,
        return_timestamps=False
    )
    
    print(f"📂 Processing: {audio_path}")
    
    # Process audio - always translate to English
    result = pipe(
        audio_path,
        generate_kwargs={
            "task": "translate",
            "language": None,  # Auto-detect
        }
    )
    
    return result["text"].strip()


def main():
    parser = argparse.ArgumentParser(
        description="StenoDrop - Transcribe audio in any language to English with AI summary",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  stenodrop audio.mp3
  stenodrop meeting.m4a --summary medium --format md
  stenodrop lecture.wav --no-summarize --output transcript.txt
  stenodrop audio.mp3 --model base --summary short
        """
    )
    
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("--model", default="small", 
                        choices=["tiny", "base", "small", "medium", "large-v2"],
                        help="Whisper model size (default: small)")
    parser.add_argument("--summary", default="short",
                        choices=["short", "medium", "long"],
                        help="Summary length (default: short)")
    parser.add_argument("--no-summarize", action="store_true",
                        help="Skip summarization, only transcribe")
    parser.add_argument("--format", default="text",
                        choices=["text", "md", "markdown"],
                        help="Output format (default: text)")
    parser.add_argument("--output", "-o", help="Save to file (optional)")
    parser.add_argument("--api-key", help="OpenAI API key (or set OPENAI_API_KEY env var)")
    
    args = parser.parse_args()
    
    try:
        # Step 1: Transcribe
        print("\n" + "="*60)
        print("🎯 STEP 1: TRANSCRIPTION")
        print("="*60)
        
        transcription = transcribe_audio(args.audio_file, args.model)
        
        print(f"\n📝 Transcription:\n{transcription}\n")
        
        # Step 2: Summarize (if not disabled)
        output_text = transcription
        
        if not args.no_summarize:
            print("="*60)
            print("🤖 STEP 2: AI SUMMARIZATION")
            print("="*60)
            
            try:
                summary_data = summarize_text(
                    transcription, 
                    length=args.summary,
                    api_key=args.api_key
                )
                
                # Format based on output type
                format_type = "markdown" if args.format in ["md", "markdown"] else "text"
                summary_output = format_summary_output(summary_data, format_type)
                
                print("\n" + summary_output)
                
                # Combine transcription + summary for file output
                if args.format in ["md", "markdown"]:
                    output_text = f"# Transcription\n\n{transcription}\n\n---\n\n{summary_output}"
                else:
                    output_text = f"TRANSCRIPTION:\n{transcription}\n\n{'='*60}\n\n{summary_output}"
                    
            except ValueError as e:
                print(f"\n⚠️  {e}")
                print("💡 Tip: Set OPENAI_API_KEY environment variable or use --api-key flag")
                print("   Skipping summarization...\n")
            except Exception as e:
                print(f"\n⚠️  Summarization failed: {e}")
                print("   Continuing with transcription only...\n")
        
        # Save to file if specified
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(output_text)
            print(f"\n💾 Saved to: {args.output}")
        
        print("\n✅ Done!\n")
        
    except FileNotFoundError:
        print(f"❌ Error: Audio file '{args.audio_file}' not found")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n\n⚠️  Interrupted by user")
        sys.exit(0)
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
