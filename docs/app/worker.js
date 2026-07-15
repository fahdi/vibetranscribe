// StenoDrop web worker, model load + inference, off the main thread.
//
// Engine: @huggingface/transformers (Transformers.js v4), ONNX Runtime Web.
// Model: onnx-community/whisper-base, multilingual Whisper base, ONNX
// build maintained by the Transformers.js team for browser use (same model
// used in Hugging Face's own official whisper-webgpu / whisper-word-timestamps
// example apps). WebGPU device with mixed dtypes (fp32 encoder / q4 decoder)
// when available, falling back to wasm with q8 dtype otherwise.
//
// Note: onnx-community/whisper-small-ONNX was tried first (better accuracy,
// same multilingual/translate support) but its exported ONNX graph fails
// under transformers.js 4.2.0 with "Missing the following inputs:
// cache_position" regardless of decoder dtype (q4/uint8/int8 all fail
// identically). This reproduces a known open compatibility issue
// (huggingface/transformers.js#1707). whisper-base does not hit it and was
// confirmed working end-to-end in a real browser.
import { pipeline } from "https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.2.0";

const MODEL_ID = "onnx-community/whisper-base";

const PER_DEVICE_CONFIG = {
  webgpu: {
    device: "webgpu",
    dtype: {
      encoder_model: "fp32",
      decoder_model_merged: "q4",
    },
  },
  wasm: {
    device: "wasm",
    dtype: "q8",
  },
};

let transcriberPromise = null;
let activeDevice = null;

async function detectDevice() {
  try {
    if (!navigator.gpu) return "wasm";
    const adapter = await navigator.gpu.requestAdapter();
    return adapter ? "webgpu" : "wasm";
  } catch {
    return "wasm";
  }
}

async function getTranscriber() {
  if (transcriberPromise) return transcriberPromise;

  transcriberPromise = (async () => {
    const device = await detectDevice();
    activeDevice = device;
    self.postMessage({ type: "device", device });

    const transcriber = await pipeline("automatic-speech-recognition", MODEL_ID, {
      ...PER_DEVICE_CONFIG[device],
      progress_callback: (progress) => {
        self.postMessage({ type: "progress", progress });
      },
    });

    self.postMessage({ type: "ready", device });
    return transcriber;
  })();

  return transcriberPromise;
}

// Warm the model as soon as the worker spins up so the download can start
// while the user is still looking at the drop zone.
getTranscriber().catch((err) => {
  self.postMessage({ type: "error", jobId: null, error: String(err && err.message ? err.message : err) });
});

/** Run one Whisper inference pass and return the flattened text. */
async function runInference(transcriber, audio, language, task) {
  // chunk_length_s/stride_length_s are only needed for audio longer than
  // Whisper's native 30s window; only pass them when the clip actually
  // exceeds that, so short clips take the plain (non-chunked) path.
  const durationSeconds = audio.length / 16000;
  const chunkOpts =
    durationSeconds > 30 ? { chunk_length_s: 30, stride_length_s: 5 } : {};

  const result = await transcriber(audio, {
    language: language === "auto" ? null : language,
    task,
    ...chunkOpts,
  });

  const text = Array.isArray(result) ? result.map((r) => r.text).join(" ") : result.text;
  return (text || "").trim();
}

self.onmessage = async (event) => {
  const msg = event.data;
  if (!msg || msg.type !== "transcribe") return;

  // `outputs` is which transcript variants the caller wants back:
  // "original" -> Whisper's plain "transcribe" task (spoken language, untranslated)
  // "english"  -> Whisper's "translate" task (always translates into English)
  // Whisper cannot target any other output language, so these two tasks are
  // the only ones that ever exist. When both are requested we simply run the
  // pipeline twice over the same decoded audio, once per task.
  const { jobId, audio, language, outputs } = msg;
  const wantOriginal = !outputs || outputs.includes("original");
  const wantEnglish = !!(outputs && outputs.includes("english"));

  try {
    const transcriber = await getTranscriber();
    const texts = {};

    if (wantOriginal) {
      texts.original = await runInference(transcriber, audio, language, "transcribe");
    }
    if (wantEnglish) {
      texts.english = await runInference(transcriber, audio, language, "translate");
    }

    self.postMessage({
      type: "done",
      jobId,
      texts,
      device: activeDevice,
    });
  } catch (err) {
    self.postMessage({
      type: "error",
      jobId,
      error: String(err && err.message ? err.message : err),
    });
  }
};
