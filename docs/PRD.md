# VibeTranscribe PRD

## 1. Product Overview
**Working name:** VibeTranscribe  
**Product type:** Local-first CLI tool → Desktop/Web SaaS  
**Primary value:** Convert audio in *any language* into **clean English text + actionable summaries**

This tool is designed for people who **think and speak in one language but work in English**.

---

## 2. Problem Statement
Many professionals record voice notes, meetings, lectures, or ideas in their native language. Existing transcription tools:
- Either don't translate well
- Or produce raw, unusable text
- Or are cloud-only, expensive, and privacy-unfriendly

Users want:
- Accurate transcription
- High-quality English translation
- A *useful summary*, not just text

---

## 3. Target Users

### Primary
- Non-native English professionals
- Developers, founders, consultants
- Students recording lectures
- Journalists / researchers
- **The Busy Professional:** Needs to turn a 30-minute meeting into a 5-bullet point summary
- **The Polyglot Student:** Records lectures in various languages and needs them translated/transcribed

### Secondary (later)
- Podcasters
- YouTubers
- Remote teams

---

## 4. Goals & Success Metrics

### Product Goals
- Enable "voice → usable English" in under 2 minutes
- Work offline or local-first where possible
- Be simple enough to use daily

### Success Metrics (Early)
- Time to first output < 2 minutes
- ≥ 80% summary usefulness (self-reported)
- CLI tool adopted by developers
- Conversion from free → paid
- Conversion rate from visit to upload
- User retention (returning to transcribe more notes)
- Accuracy ratings from users

---

## 5. Non-Goals
- Real-time transcription (v1)
- Speaker diarization
- Meeting bots / calendar integrations
- Social or collaboration features

---

## 6. User Stories

### CLI User
> As a developer, I want to transcribe an audio file in any language and receive an English summary via the command line.

### Knowledge Worker
> As a professional, I want to upload a voice note and get a short English summary I can share or store.

### Student
> As a student, I want to record lectures and get concise notes in English.

---

## 7. Functional Requirements

### 7.1 Audio Upload & Processing
- **FR1:** User can drag and drop or select audio files (max 25MB initially)
- **FR2:** Support formats: `.mp3`, `.wav`, `.m4a`, `.ogg`
- **FR3:** Visual feedback (progress bar) during upload and processing

### 7.2 Transcription
- **FR4:** Auto-detection of audio language
- **FR5:** High-accuracy transcription output
- **FR6:** Display transcription with timestamps

### 7.3 Summarization
- **FR7:** Generate a concise summary of the transcription
- **FR8:** Extract "Action Items" and "Key Insights"
- **FR9:** Ability to toggle summary length (Short, Medium, Long/Detailed)

### 7.4 User Interface
- **FR10:** Modern, dark-themed responsive UI
- **FR11:** Accessible design (screen reader friendly)
- **FR12:** Mobile-responsive layout

---

## 8. MVP Scope (Phase 1 – CLI)

### Inputs
- Audio file (`.mp3`, `.wav`, `.m4a`)
- Optional flags:
  - Summary length: `short | medium | long`
  - Output format: `txt | md | json`

### Processing Pipeline
1. Language detection
2. Transcription (source language)
3. Translation to English
4. Summarization

### Outputs
- Original transcript
- English transcript
- Summary

Example CLI:
```bash
vibetranscribe meeting.m4a --summary short --format md
```

---

## 9. MVP Scope (Phase 2 – UI)

### Features
- Upload or record audio
- Auto language detection
- Summary type: bullet points, action items
- Download/export results
- History (last N files)

---

## 10. UX Principles
- Minimal UI
- One primary action: **Upload → Process → Get Result**
- No login required for free tier
- Clear indication of credit usage

---

## 11. Technical Architecture

### Technical Stack
- **Frontend:** React (Vite, TypeScript), Tailwind CSS (for layout) or Vanilla CSS (for custom premium feel), Framer Motion (animations)
- **Testing:** Vitest, React Testing Library (for TDD)
- **Icons:** Lucide React
- **State Management:** React Context or Zustand

### Local / CLI
- Audio ingestion
- Transcription engine (local or API)
- Translation layer
- Summarization layer

### SaaS Layer (Later)
- Auth
- Usage tracking
- Billing
- Model orchestration

---

## 12. Non-Functional Requirements
- **NFR1 (Performance):** Transcription for 5-minute audio should complete in < 30 seconds
- **NFR2 (Security):** Secure file handling (files deleted after processing or stored encrypted)
- **NFR3 (Scalability):** System should handle multiple concurrent uploads

---

## 13. Privacy & Security
- Local processing by default (CLI)
- No audio stored without explicit user consent
- Clear data deletion policy for SaaS

---

## 14. Monetization Strategy

### Free Tier
- Limited minutes/month
- Basic summaries

### Paid Plans
- Tiered by minutes/credits
- Higher quality summaries
- Priority processing

Indicative pricing:
- $10/month – 5 hours
- $25/month – 15 hours

---

## 15. Risks & Mitigations
| Risk | Mitigation |
|----|---|
| High AI costs | Credit-based system |
| Poor translations | Model tuning & language focus |
| Commoditization | Focus on underserved languages |

---

## 16. Future Enhancements (Out of Scope for MVP)
- Meeting summaries
- Team workspaces
- Integrations (Notion, Jira)
- Mobile app
- Offline desktop models

---

## 17. Launch Plan (YouTube-Friendly)
1. Day 1: CLI tool working end-to-end
2. Day 3: Polish summaries & outputs
3. Day 7: Desktop UI
4. Day 14: Freemium SaaS

---

## 18. Why This Can Hit $1M
- Massive non-English market
- Clear recurring value
- AI cost maps directly to pricing
- Strong personal brand + live building
