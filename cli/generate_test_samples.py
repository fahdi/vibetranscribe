#!/usr/bin/env python3
"""
Generate test audio samples in multiple languages
"""

from gtts import gTTS
import os

# Test samples in different languages
TEST_SAMPLES = {
    "english.mp3": {
        "text": "Hello, this is a test recording. Today I will discuss three important points about our project timeline, budget allocation, and team responsibilities.",
        "lang": "en",
        "description": "English - Project meeting"
    },
    "spanish.mp3": {
        "text": "Hola, esta es una grabación de prueba. Hoy discutiré tres puntos importantes sobre el cronograma del proyecto, la asignación de presupuesto y las responsabilidades del equipo.",
        "lang": "es",
        "description": "Spanish - Same content as English"
    },
    "french.mp3": {
        "text": "Bonjour, ceci est un enregistrement de test. Aujourd'hui, je vais discuter de trois points importants concernant le calendrier du projet, l'allocation budgétaire et les responsabilités de l'équipe.",
        "lang": "fr",
        "description": "French - Same content"
    },
    "german.mp3": {
        "text": "Hallo, dies ist eine Testaufnahme. Heute werde ich drei wichtige Punkte besprechen: Projektzeitplan, Budgetzuweisung und Teamverantwortlichkeiten.",
        "lang": "de",
        "description": "German - Same content"
    },
    "urdu.mp3": {
        "text": "ہیلو، یہ ایک ٹیسٹ ریکارڈنگ ہے۔ آج میں پروجیکٹ کی ٹائم لائن، بجٹ مختص کرنے اورٹیم کی ذمہ داریوں کے بارے میں تین اہم نکات پر بات کروں گا۔",
        "lang": "ur",
        "description": "Urdu - Same content"
    },
    "japanese.mp3": {
        "text": "こんにちは、これはテスト録音です。今日は、プロジェクトのタイムライン、予算配分、チームの責任について3つの重要なポイントを説明します。",
        "lang": "ja",
        "description": "Japanese - Same content"
    },
    "meeting_notes.mp3": {
        "text": "Action items from today's meeting: First, John will complete the database migration by Friday. Second, Sarah needs to review the API documentation. Third, we need to schedule a follow-up meeting next week to discuss the results.",
        "lang": "en",
        "description": "English - Meeting with action items"
    }
}

def generate_samples(output_dir="../test-audio/generated"):
    """Generate all test audio samples"""
    
    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)
    
    print("🎙️  Generating test audio samples...\n")
    
    for filename, sample in TEST_SAMPLES.items():
        output_path = os.path.join(output_dir, filename)
        
        print(f"Creating: {filename}")
        print(f"  Language: {sample['lang']}")
        print(f"  Description: {sample['description']}")
        
        # Generate audio
        tts = gTTS(text=sample['text'], lang=sample['lang'], slow=False)
        tts.save(output_path)
        
        print(f"  ✅ Saved to: {output_path}\n")
    
    print(f"\n✨ Generated {len(TEST_SAMPLES)} test samples!")
    print(f"📁 Location: {output_dir}")
    print("\nYou can now test with:")
    print(f"  python vibetranscribe.py {output_dir}/english.mp3")
    print(f"  python vibetranscribe.py {output_dir}/spanish.mp3 --summary medium")
    print(f"  python vibetranscribe.py {output_dir}/meeting_notes.mp3 --format md")

if __name__ == "__main__":
    generate_samples()
