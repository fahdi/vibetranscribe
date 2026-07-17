// StenoDrop web app, main thread. Handles file/folder ingestion, audio
// decode + resample to 16kHz mono (Whisper's required input), the batch
// queue UI, and downloads (per-file .txt, all-as-.zip). All model work
// happens in worker.js so this thread never blocks.
import { downloadZip } from "https://cdn.jsdelivr.net/npm/client-zip@2.5.0/index.js";
import {
  parseCaptions,
  reflow,
  chunkCues,
  redistribute,
  serializeCaptions,
  flattenedText,
  captionOutputName,
  formatFromExtension,
} from "./captions.js";

// Placeholder for the not-yet-deployed cloud transcription server (see
// docs/superpowers/specs/2026-07-16-cloud-transcription-design.md for the
// API contract and full architecture). This will not respond until the
// server is actually deployed to isupercoder.com; the reachability check
// below (checkCloudAvailability) handles that gracefully by disabling the
// Cloud mode option rather than letting anyone pick it and hit a dead end.
// Update this single constant once the real server is live.
const CLOUD_API_BASE = "https://api.isupercoder.com/stenodrop";
const CLOUD_HEALTH_TIMEOUT_MS = 3500;
const CLOUD_REQUEST_TIMEOUT_MS = 120000;

// Same 19-language + auto list as the native apps (mac/Sources/StenoDrop/JobQueue.swift).
const LANGUAGES = [
  ["auto", "Auto-detect"],
  ["ur", "Urdu"],
  ["en", "English"],
  ["ar", "Arabic"],
  ["bn", "Bengali"],
  ["zh", "Chinese"],
  ["fr", "French"],
  ["de", "German"],
  ["hi", "Hindi"],
  ["id", "Indonesian"],
  ["it", "Italian"],
  ["ja", "Japanese"],
  ["ko", "Korean"],
  ["fa", "Persian"],
  ["pt", "Portuguese"],
  ["pa", "Punjabi"],
  ["ps", "Pashto"],
  ["ru", "Russian"],
  ["es", "Spanish"],
  ["tr", "Turkish"],
];

const AUDIO_EXTENSIONS = new Set([
  "wav", "mp3", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus",
  "aiff", "aif", "caf", "amr", "wma", "3gp",
  "mp4", "mov", "m4v", "avi", "webm", "mkv",
]);

// Caption files are already transcripts with timing: they skip Whisper
// entirely and go through the caption pipeline (cleanup + translation).
const CAPTION_EXTENSIONS = new Set(["srt", "vtt"]);

const WHISPER_SAMPLE_RATE = 16000;

// ---------- settings persistence ----------
// The original-language transcript is always produced. On top of that the
// user picks any number of target languages; each adds its own output file.
// Translation runs through the browser's built-in Translator API when it
// exists; when it doesn't, English (and only English) can still come from
// Whisper's own translate task (see worker.js), and other languages get a
// visible per-language note.
const SETTINGS_KEY = "stenodrop-web-settings";
const DEFAULT_SETTINGS = { language: "auto", targets: ["en"], mode: "offline" };
const KNOWN_TARGETS = new Set(LANGUAGES.map(([code]) => code).filter((code) => code !== "auto"));

function loadSettings() {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return { ...DEFAULT_SETTINGS, targets: [...DEFAULT_SETTINGS.targets] };
    const parsed = JSON.parse(raw);
    let targets;
    if (Array.isArray(parsed.targets)) {
      targets = parsed.targets.filter((code) => KNOWN_TARGETS.has(code));
    } else if (parsed.outputs && typeof parsed.outputs === "object") {
      // Migration from the legacy {original, english} checkbox pair:
      // "English translation" checked becomes the single target "en".
      targets = parsed.outputs.english ? ["en"] : [];
    } else {
      targets = [...DEFAULT_SETTINGS.targets];
    }
    return {
      language: typeof parsed.language === "string" ? parsed.language : DEFAULT_SETTINGS.language,
      targets,
      mode: parsed.mode === "cloud" ? "cloud" : "offline",
    };
  } catch (e) {
    return { ...DEFAULT_SETTINGS, targets: [...DEFAULT_SETTINGS.targets] };
  }
}

function saveSettings() {
  try {
    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify({
        language: languageSelect.value,
        targets: selectedTargets(),
        mode: currentMode,
      })
    );
  } catch (e) {
    // localStorage unavailable (e.g. private browsing) - settings just won't persist.
  }
}

// ---------- DOM ----------
const dropZone = document.getElementById("drop-zone");
const fileInput = document.getElementById("file-input");
const folderInput = document.getElementById("folder-input");
const pickFilesBtn = document.getElementById("pick-files-btn");
const pickFolderBtn = document.getElementById("pick-folder-btn");
const languageSelect = document.getElementById("language-select");
const targetListEl = document.getElementById("target-list");
const translatorNote = document.getElementById("translator-note");
const queueEl = document.getElementById("queue");
const queueSection = document.getElementById("queue-section");
const downloadAllBtn = document.getElementById("download-all-btn");
const modelStatus = document.getElementById("model-status");
const modelStatusText = document.getElementById("model-status-text");
const modelProgressBar = document.getElementById("model-progress-bar");
const deviceNote = document.getElementById("device-note");
const modeOfflineBtn = document.getElementById("mode-offline-btn");
const modeCloudBtn = document.getElementById("mode-cloud-btn");
const modeCloudNote = document.getElementById("mode-cloud-note");

// ---------- state ----------
/** @type {{id:string, file:File, status:string, texts:Object<string,string>, error:string}[]} */
let jobs = [];
let jobSeq = 0;
let isProcessing = false;
let modelReady = false;
let downloadTotals = new Map(); // file -> {loaded, total}
let currentMode = "offline"; // "offline" | "cloud"
let cloudAvailable = null; // null = still checking, true/false once the /health check settles

// ---------- language picker ----------
for (const [code, name] of LANGUAGES) {
  const opt = document.createElement("option");
  opt.value = code;
  opt.textContent = name;
  languageSelect.appendChild(opt);
}

// ---------- target language multi-select ----------
const targetChecks = new Map();
for (const [code, name] of LANGUAGES) {
  if (code === "auto") continue;
  const label = document.createElement("label");
  label.className = "toggle-row";
  const input = document.createElement("input");
  input.type = "checkbox";
  input.value = code;
  input.addEventListener("change", saveSettings);
  label.appendChild(input);
  label.appendChild(document.createTextNode(" " + name));
  targetChecks.set(code, input);
  targetListEl.appendChild(label);
}

/** The target language codes currently checked. Zero targets is a valid
 * state: the original transcript is always produced regardless. */
function selectedTargets() {
  const targets = [];
  for (const [code, input] of targetChecks) {
    if (input.checked) targets.push(code);
  }
  return targets;
}

/** True when the browser ships the built-in Translator API (Chrome 138+). */
function translatorAvailable() {
  return "Translator" in self;
}

if (!translatorAvailable()) {
  translatorNote.hidden = false;
  translatorNote.textContent =
    "This browser doesn't include built-in translation (Chrome and Edge on desktop do). English can still come straight from the speech model. Other languages will be skipped with a note on each file.";
}

// ---------- settings: load persisted, wire up saving ----------
const initialSettings = loadSettings();
languageSelect.value = initialSettings.language;
if (languageSelect.value !== initialSettings.language) {
  // Stored language code no longer exists in the list; fall back cleanly.
  languageSelect.value = "auto";
}
for (const code of initialSettings.targets) {
  const input = targetChecks.get(code);
  if (input) input.checked = true;
}
currentMode = initialSettings.mode;

languageSelect.addEventListener("change", saveSettings);

// ---------- mode picker (offline / cloud) ----------
function setMode(mode) {
  if (mode === "cloud" && cloudAvailable === false) return; // can't select a mode we know is unreachable
  currentMode = mode;
  modeOfflineBtn.classList.toggle("active", mode === "offline");
  modeOfflineBtn.setAttribute("aria-pressed", String(mode === "offline"));
  modeCloudBtn.classList.toggle("active", mode === "cloud");
  modeCloudBtn.setAttribute("aria-pressed", String(mode === "cloud"));
  saveSettings();
}

modeOfflineBtn.addEventListener("click", () => setMode("offline"));
modeCloudBtn.addEventListener("click", () => setMode("cloud"));

// Reflect the persisted mode in the UI immediately; the cloud reachability
// check below may still downgrade it to disabled/offline if the server
// isn't responding, but we don't want to wait on the network for the
// initial paint.
setMode(currentMode);

/**
 * Check whether the cloud endpoint is up. Runs in the background on page
 * load (never blocks initial render) and updates the Cloud option once it
 * settles: enabled if healthy, disabled with an honest note otherwise. If
 * the user had Cloud selected from a previous visit but it's unreachable
 * now, fall back to Offline rather than leaving a dead-end mode selected.
 */
async function checkCloudAvailability() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CLOUD_HEALTH_TIMEOUT_MS);
  try {
    const res = await fetch(CLOUD_API_BASE + "/health", { signal: controller.signal });
    if (!res.ok) throw new Error("health check returned " + res.status);
    await res.json();
    cloudAvailable = true;
    modeCloudBtn.disabled = false;
    modeCloudBtn.removeAttribute("aria-disabled");
    modeCloudNote.hidden = true;
    modeCloudNote.classList.remove("mode-unavailable");
  } catch (e) {
    cloudAvailable = false;
    modeCloudBtn.disabled = true;
    modeCloudBtn.setAttribute("aria-disabled", "true");
    modeCloudNote.hidden = false;
    modeCloudNote.classList.add("mode-unavailable");
    modeCloudNote.textContent = "Cloud processing isn't available right now. Offline still works normally.";
    if (currentMode === "cloud") setMode("offline");
  } finally {
    clearTimeout(timer);
  }
}
checkCloudAvailability();

// ---------- worker ----------
const worker = new Worker("./worker.js", { type: "module" });

worker.onmessage = (event) => {
  const msg = event.data;
  switch (msg.type) {
    case "device":
      handleDevice(msg.device);
      break;
    case "progress":
      handleProgress(msg.progress);
      break;
    case "ready":
      handleReady(msg.device);
      break;
    case "done":
      handleDone(msg.jobId, msg.texts);
      break;
    case "error":
      handleError(msg.jobId, msg.error);
      break;
  }
};

function handleDevice(device) {
  if (device === "wasm") {
    deviceNote.hidden = false;
    deviceNote.textContent =
      "Your browser doesn't support hardware acceleration here, so transcription will run a bit slower. It still works fine. Chrome or Edge on desktop currently offer the fastest experience.";
  } else {
    deviceNote.hidden = false;
    deviceNote.textContent = "Running with hardware acceleration.";
  }
}

function handleProgress(progress) {
  if (!progress || progress.status !== "progress" && progress.status !== "initiate" && progress.status !== "done") {
    // Some progress events (e.g. "ready") don't carry file/loaded data. Ignore them.
  }
  if (progress.file) {
    if (progress.status === "progress") {
      downloadTotals.set(progress.file, { loaded: progress.loaded || 0, total: progress.total || 0 });
    } else if (progress.status === "done") {
      downloadTotals.set(progress.file, { loaded: 1, total: 1, done: true });
    }
  }

  let loaded = 0;
  let total = 0;
  for (const v of downloadTotals.values()) {
    loaded += v.loaded;
    total += v.total || v.loaded;
  }
  const pct = total > 0 ? Math.min(100, Math.round((loaded / total) * 100)) : 0;

  modelStatus.hidden = false;
  modelProgressBar.style.width = pct + "%";
  modelStatusText.textContent =
    `Downloading the voice-recognition software, ${pct}% (${(loaded / 1e6).toFixed(0)} MB of ${(total / 1e6).toFixed(0)} MB). This happens once, then it's cached in your browser.`;
}

function handleReady() {
  modelReady = true;
  modelStatusText.textContent = "Ready. Transcribing from your browser's cache.";
  modelProgressBar.style.width = "100%";
  setTimeout(() => {
    if (modelReady) modelStatus.hidden = true;
  }, 1800);
  pump();
}

function handleDone(jobId, texts) {
  const job = jobs.find((j) => j.id === jobId);
  if (!job) return;
  job.texts = texts || {};
  finishAudioJob(job);
}

function handleError(jobId, error) {
  if (jobId == null) {
    // Model-load-level error, not tied to a specific job.
    modelStatusText.textContent = "Model failed to load: " + error;
    return;
  }
  const job = jobs.find((j) => j.id === jobId);
  if (!job) return;
  job.status = "failed";
  job.error = error;
  renderQueue();
  isProcessing = false;
  pump();
  maybeShowDownloadAll();
}

// ---------- ingestion ----------
function extOf(name) {
  const i = name.lastIndexOf(".");
  return i === -1 ? "" : name.slice(i + 1).toLowerCase();
}

function addFiles(fileList) {
  const files = Array.from(fileList).filter(
    (f) => AUDIO_EXTENSIONS.has(extOf(f.name)) || CAPTION_EXTENSIONS.has(extOf(f.name))
  );
  if (files.length === 0) return;
  for (const file of files) {
    const kind = CAPTION_EXTENSIONS.has(extOf(file.name)) ? "caption" : "audio";
    jobs.push({
      id: String(jobSeq++),
      file,
      kind,
      status: "queued",
      texts: {},
      outputs: [],
      notes: [],
      previewText: "",
      error: "",
    });
  }
  queueSection.hidden = false;
  renderQueue();
  pump();
}

async function collectDataTransferFiles(dataTransfer) {
  const items = dataTransfer.items;
  if (!items) return Array.from(dataTransfer.files || []);

  const out = [];
  const entries = [];
  for (const item of items) {
    const entry = item.webkitGetAsEntry && item.webkitGetAsEntry();
    if (entry) entries.push(entry);
  }

  if (entries.length === 0) return Array.from(dataTransfer.files || []);

  async function walk(entry) {
    if (entry.isFile) {
      const file = await new Promise((res, rej) => entry.file(res, rej));
      out.push(file);
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      const readAll = async () => {
        const batch = await new Promise((res, rej) => reader.readEntries(res, rej));
        if (batch.length === 0) return [];
        return batch.concat(await readAll());
      };
      const children = await readAll();
      for (const child of children) await walk(child);
    }
  }

  for (const entry of entries) await walk(entry);
  return out;
}

// ---------- queue processing ----------
function pump() {
  if (isProcessing) return;
  const next = jobs.find((j) => j.status === "queued");
  if (!next) return;

  isProcessing = true;
  // Snapshot the settings this job runs with, so mid-job checkbox changes
  // never produce a mixed result.
  next.targets = selectedTargets();
  next.language = languageSelect.value;

  if (next.kind === "caption") {
    // Caption files never touch Whisper or the cloud server: parsing and
    // cleanup run right here, translation uses the browser's built-in
    // Translator when it exists.
    next.status = "cleaning";
    renderQueue();
    runCaptionJob(next);
    return;
  }

  next.status = "transcribing";
  renderQueue();

  if (currentMode === "cloud") {
    runCloudJob(next);
    return;
  }

  decodeToPCM(next.file)
    .then((audio) => {
      worker.postMessage(
        {
          type: "transcribe",
          jobId: next.id,
          audio,
          language: next.language,
          outputs: whisperOutputs(next),
        },
        [audio.buffer]
      );
    })
    .catch((err) => {
      handleError(next.id, "Couldn't decode audio: " + (err.message || err));
    });
}

/**
 * Which Whisper tasks a job needs. The original transcript always runs.
 * Whisper's own translate task can only ever target English; it is kept as
 * the "en" fallback for browsers without the built-in Translator API. When
 * the Translator exists, every target (English included) goes through it
 * instead, off the original transcript.
 */
function whisperOutputs(job) {
  const outputs = ["original"];
  if (job.targets.includes("en") && !translatorAvailable()) outputs.push("english");
  return outputs;
}

/**
 * Run one job through the cloud API instead of the local worker pipeline.
 * The cloud API exposes the same two Whisper tasks as the worker (a single
 * `translate` boolean), so the request set mirrors whisperOutputs(): the
 * original transcript always, plus a translate=true request only when "en"
 * is selected and the built-in Translator is absent. All other target
 * languages are translated client-side afterwards, exactly like Offline
 * mode. Requests run in parallel; if one fails and the other succeeds we
 * still record the text we got and surface only the failed half's error.
 */
async function runCloudJob(job) {
  const requests = whisperOutputs(job).map((kind) =>
    cloudTranscribe(job.file, job.language, kind === "english").then(
      (text) => ({ kind, ok: true, text }),
      (err) => ({ kind, ok: false, error: String(err && err.message ? err.message : err) })
    )
  );

  const results = await Promise.all(requests);
  const texts = {};
  const errors = [];
  for (const r of results) {
    if (r.ok) texts[r.kind] = r.text;
    else errors.push(`${r.kind}: ${r.error}`);
  }

  if (Object.keys(texts).length === 0) {
    handleError(job.id, errors.join(" / ") || "Cloud transcription failed.");
    return;
  }

  if (errors.length > 0) {
    // Partial success: at least one output came back. Surface the failure
    // for the other one without discarding the text we did get.
    job.error = "Some outputs failed: " + errors.join(" / ");
  }
  job.texts = texts;
  finishAudioJob(job);
}

/** POST one file to the cloud /transcribe endpoint. Returns the transcript text or throws. */
async function cloudTranscribe(file, language, translate) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CLOUD_REQUEST_TIMEOUT_MS);
  try {
    const form = new FormData();
    form.append("file", file, file.name);
    form.append("language", language);
    form.append("translate", translate ? "true" : "false");

    let res;
    try {
      res = await fetch(CLOUD_API_BASE + "/transcribe", {
        method: "POST",
        body: form,
        signal: controller.signal,
      });
    } catch (err) {
      if (err && err.name === "AbortError") {
        throw new Error("Request timed out. The server took too long to respond.");
      }
      throw new Error("Couldn't reach the cloud server. Check your internet connection.");
    }

    let payload = null;
    try {
      payload = await res.json();
    } catch (e) {
      // Non-JSON response body; fall through to the generic status-based error below.
    }

    if (!res.ok) {
      const message = (payload && payload.error) || `Server returned ${res.status}.`;
      throw new Error(message);
    }
    if (!payload || typeof payload.text !== "string") {
      throw new Error("Server returned an unexpected response.");
    }
    return payload.text;
  } finally {
    clearTimeout(timer);
  }
}

// ---------- caption jobs (see captions.js for the pure pipeline) ----------

/** English-locale language names so notes read naturally ("Urdu", not "ur"). */
const languageDisplayNames = (() => {
  try {
    return new Intl.DisplayNames(["en"], { type: "language" });
  } catch (e) {
    return null;
  }
})();

function displayName(code) {
  if (!code || code === "und") return "the source language";
  try {
    return (languageDisplayNames && languageDisplayNames.of(code)) || code;
  } catch (e) {
    return code;
  }
}

/** Primary-subtag comparison, never raw strings: zh-Hans and zh match. */
function sameLanguage(a, b) {
  if (!a || !b) return false;
  return a.split("-")[0].toLowerCase() === b.split("-")[0].toLowerCase();
}

/** Best-effort source language detection via the browser's built-in
 * LanguageDetector, when it exists. Returns a BCP-47 code or null. */
async function detectLanguage(sample) {
  if (!("LanguageDetector" in self)) return null;
  try {
    const detector = await LanguageDetector.create();
    const results = await detector.detect(sample.slice(0, 1000));
    const top = results && results[0];
    if (top && top.detectedLanguage && top.detectedLanguage !== "und" && top.confidence > 0.5) {
      return top.detectedLanguage;
    }
  } catch (e) {
    // Detection is best-effort; translation gets a per-language note instead.
  }
  return null;
}

/**
 * Create a translator for one source/target pair via the browser's built-in
 * Translator API. Every failure path pushes a visible per-language note
 * (ending with `keptNote`, which says what the user still gets) and returns
 * null; nothing here fails silently. Language packs download on first use
 * inside Translator.create().
 */
async function createTranslator(sourceLang, target, notes, keptNote) {
  const targetName = displayName(target);
  if (!translatorAvailable()) {
    notes.push(
      `${targetName} translation isn't available in this browser. It needs the built-in translator (Chrome and Edge on desktop have it). ${keptNote}`
    );
    return null;
  }
  if (!sourceLang) {
    notes.push(
      `Couldn't determine the source language, so ${targetName} translation was skipped. Pick the language above and re-add the file.`
    );
    return null;
  }
  try {
    const availability = await Translator.availability({
      sourceLanguage: sourceLang,
      targetLanguage: target,
    });
    if (availability === "unavailable") {
      notes.push(
        `This browser can't translate ${displayName(sourceLang)} to ${targetName}. ${keptNote}`
      );
      return null;
    }
    return await Translator.create({
      sourceLanguage: sourceLang,
      targetLanguage: target,
    });
  } catch (err) {
    notes.push(
      `${targetName} translation couldn't start: ${String(err && err.message ? err.message : err)}. ${keptNote}`
    );
    return null;
  }
}

const KEPT_TRANSCRIPT_NOTE = "The original transcript is still included.";
const KEPT_TRACK_NOTE = "The cleaned track is still saved.";

/**
 * Translate a long text through one translator in sentence-aligned batches,
 * so single Translator calls stay a manageable size. Batches are joined
 * back with single spaces.
 */
async function translateLongText(translator, text, sourceLang) {
  const MAX_BATCH = 2000;
  let segmenter;
  try {
    segmenter = new Intl.Segmenter(sourceLang || undefined, { granularity: "sentence" });
  } catch (e) {
    segmenter = new Intl.Segmenter(undefined, { granularity: "sentence" });
  }
  const batches = [];
  let current = "";
  for (const { segment } of segmenter.segment(text)) {
    if (current && current.length + segment.length > MAX_BATCH) {
      batches.push(current);
      current = "";
    }
    current += segment;
    // Pathological single "sentence" far beyond the cap: hard-split it.
    while (current.length > MAX_BATCH * 2) {
      batches.push(current.slice(0, MAX_BATCH * 2));
      current = current.slice(MAX_BATCH * 2);
    }
  }
  if (current) batches.push(current);
  const out = [];
  for (const batch of batches) {
    out.push(await translator.translate(batch));
  }
  return out.join(" ").trim();
}

/** `name.txt` for the original transcript, `name.<lang>.txt` per target. */
function audioOutputName(fileName, lang) {
  return baseName(fileName) + "." + lang + ".txt";
}

/**
 * Finish an audio job once Whisper (worker or cloud) has returned: build the
 * output file list, then translate the original transcript into each
 * selected target language through the built-in Translator API. "en" uses
 * the Whisper translate result when that fallback ran. Skipped or failed
 * languages get a visible note, never a silent omission.
 */
async function finishAudioJob(job) {
  const texts = job.texts || {};
  const targets = job.targets || [];
  const notes = job.notes || [];
  const outputs = [];

  if (typeof texts.original === "string") {
    outputs.push({ label: "Original", name: txtName(job.file.name), text: texts.original });
  }

  const original = typeof texts.original === "string" ? texts.original : "";
  let sourceLang = job.language !== "auto" ? job.language : null;
  if (!sourceLang && targets.length > 0 && original) {
    sourceLang = await detectLanguage(original);
  }

  for (const target of targets) {
    const targetName = displayName(target);
    if (target === "en" && typeof texts.english === "string") {
      // Whisper's own translate task already produced this one.
      outputs.push({ label: "English", name: audioOutputName(job.file.name, "en"), text: texts.english });
      continue;
    }
    if (!original) {
      notes.push(`${targetName} skipped, there is no original transcript to translate.`);
      continue;
    }
    if (sourceLang && sameLanguage(sourceLang, target)) {
      notes.push(`${targetName} skipped, the recording is already ${displayName(sourceLang)}.`);
      continue;
    }
    const translator = await createTranslator(sourceLang, target, notes, KEPT_TRANSCRIPT_NOTE);
    if (!translator) continue;
    job.status = "translating";
    renderQueue();
    try {
      const translated = await translateLongText(translator, original, sourceLang);
      outputs.push({ label: targetName, name: audioOutputName(job.file.name, target), text: translated });
    } catch (err) {
      notes.push(
        `${targetName} translation failed: ${String(err && err.message ? err.message : err)}`
      );
    }
    if (typeof translator.destroy === "function") translator.destroy();
  }

  job.outputs = outputs;
  job.notes = notes;
  job.status = "done";
  renderQueue();
  isProcessing = false;
  pump();
  maybeShowDownloadAll();
}

/**
 * Run one caption job: parse, reflow (rolling-caption cleanup), always emit
 * the cleaned source track plus a flattened .txt, then one translated track
 * plus .txt per selected target language via the Translator API. Unsupported
 * pairs get a visible note, never a silent failure.
 */
async function runCaptionJob(job) {
  try {
    const format = formatFromExtension(extOf(job.file.name));
    const data = new Uint8Array(await job.file.arrayBuffer());
    const parsed = parseCaptions(data, format);
    const notes = [...parsed.warnings];
    const result = reflow(parsed.cues);
    const flattened = flattenedText(result.cues);

    // Source language priority: VTT Language header, then the picker when
    // not auto, then best-effort detection.
    let sourceLang = parsed.language ? parsed.language.trim() : null;
    if (!sourceLang && languageSelect.value !== "auto") sourceLang = languageSelect.value;
    if (!sourceLang) sourceLang = await detectLanguage(flattened);
    const sourceCode = sourceLang || "und";

    // The cleaned source track is always produced. For languages the
    // Translator can't serve, it is the whole feature.
    const outputs = [
      {
        label: "Cleaned " + format,
        name: captionOutputName(job.file.name, sourceCode, format),
        text: serializeCaptions(result.cues, format, format === "vtt" ? sourceCode : null),
      },
      {
        label: "Text",
        name: captionOutputName(job.file.name, sourceCode, "txt"),
        text: flattened + "\n",
      },
    ];

    const chunks = chunkCues(result.cues, result.runBoundaries);
    for (const target of job.targets || []) {
      const targetName = displayName(target);
      if (sourceLang && sameLanguage(sourceLang, target)) {
        notes.push(
          `${targetName} skipped, the captions are already ${displayName(sourceCode)}. Cleaned track saved.`
        );
        continue;
      }
      const translator = await createTranslator(sourceLang, target, notes, KEPT_TRACK_NOTE);
      if (!translator) continue;

      job.status = "translating";
      renderQueue();

      const outputCues = [];
      let untranslated = 0;
      for (const chunk of chunks) {
        let translated = "";
        try {
          translated = await translator.translate(chunk.text);
        } catch (err) {
          translated = ""; // Chunk falls back to cleaned source text below.
        }
        const redistribution = redistribute(translated, chunk, result.cues, target);
        if (redistribution.usedSourceFallback) untranslated += 1;
        outputCues.push(...redistribution.cues);
      }
      if (untranslated > 0) {
        notes.push(`${targetName}: ${untranslated} of ${chunks.length} segments untranslated`);
      }
      outputs.push({
        label: targetName + " " + format,
        name: captionOutputName(job.file.name, target, format),
        text: serializeCaptions(outputCues, format, format === "vtt" ? target : null),
      });
      outputs.push({
        label: targetName + " text",
        name: captionOutputName(job.file.name, target, "txt"),
        text: flattenedText(outputCues) + "\n",
      });
      if (typeof translator.destroy === "function") translator.destroy();
    }

    job.outputs = outputs;
    job.notes = notes;
    job.previewText = flattened;
    job.status = "done";
  } catch (err) {
    job.status = "failed";
    job.error = String(err && err.message ? err.message : err);
  }
  renderQueue();
  isProcessing = false;
  pump();
  maybeShowDownloadAll();
}

/** Decode an audio File via Web Audio API and resample to 16kHz mono Float32. */
async function decodeToPCM(file) {
  const arrayBuffer = await file.arrayBuffer();
  const AudioCtx = window.AudioContext || window.webkitAudioContext;
  // Decode at the file's native rate first (decodeAudioData needs a context,
  // but we don't need it to run at 16kHz; OfflineAudioContext handles resampling).
  const probeCtx = new AudioCtx();
  let decoded;
  try {
    decoded = await probeCtx.decodeAudioData(arrayBuffer.slice(0));
  } finally {
    probeCtx.close();
  }

  if (decoded.sampleRate === WHISPER_SAMPLE_RATE && decoded.numberOfChannels === 1) {
    return decoded.getChannelData(0).slice();
  }

  const durationSeconds = decoded.duration;
  const offlineCtx = new OfflineAudioContext(
    1,
    Math.ceil(durationSeconds * WHISPER_SAMPLE_RATE),
    WHISPER_SAMPLE_RATE
  );
  const source = offlineCtx.createBufferSource();
  source.buffer = decoded;
  source.connect(offlineCtx.destination);
  source.start(0);
  const rendered = await offlineCtx.startRendering();
  return rendered.getChannelData(0).slice();
}

// ---------- UI rendering ----------
const STATUS_LABEL = {
  queued: "Queued",
  transcribing: "Transcribing…",
  cleaning: "Cleaning captions…",
  translating: "Translating…",
  done: "Done",
  failed: "Failed",
};

function renderQueue() {
  queueEl.innerHTML = "";
  for (const job of jobs) {
    const row = document.createElement("div");
    row.className = "q-row q-" + job.status;

    const name = document.createElement("div");
    name.className = "q-name";
    name.textContent = job.file.name;

    const status = document.createElement("div");
    status.className = "q-status";
    status.textContent = STATUS_LABEL[job.status] || job.status;

    const actions = document.createElement("div");
    actions.className = "q-actions";

    if (job.status === "done") {
      const files = outputFiles(job);
      for (const f of files) {
        const dlBtn = document.createElement("button");
        dlBtn.className = "btn-mini";
        dlBtn.textContent = files.length > 1 ? `↓ ${f.label}` : "↓ .txt";
        dlBtn.addEventListener("click", () => downloadFile(f.name, f.text));
        actions.appendChild(dlBtn);
      }

      const copyBtn = document.createElement("button");
      copyBtn.className = "btn-mini";
      copyBtn.textContent = "Copy";
      copyBtn.addEventListener("click", () => {
        const combined =
          job.kind === "caption"
            ? job.previewText
            : files.map((f) => (files.length > 1 ? `[${f.label}]\n${f.text}` : f.text)).join("\n\n");
        navigator.clipboard.writeText(combined).then(() => {
          copyBtn.textContent = "Copied ✓";
          setTimeout(() => (copyBtn.textContent = "Copy"), 1400);
        });
      });
      actions.appendChild(copyBtn);
    }

    row.appendChild(name);
    row.appendChild(status);
    row.appendChild(actions);

    if (job.status === "done") {
      if (job.kind === "caption") {
        // One preview of the cleaned, deduplicated text; the timed tracks
        // are download-only (dumping full SRT/VTT here would be noise).
        const transcript = document.createElement("div");
        transcript.className = "q-transcript";
        transcript.textContent = job.previewText || "(empty captions)";
        row.appendChild(transcript);
      } else {
        const files = outputFiles(job);
        for (const f of files) {
          const transcript = document.createElement("div");
          transcript.className = "q-transcript";
          transcript.textContent =
            (files.length > 1 ? `[${f.label}] ` : "") + (f.text || "(empty transcript)");
          row.appendChild(transcript);
        }
      }
      for (const note of job.notes || []) {
        const noteEl = document.createElement("div");
        noteEl.className = "q-note";
        noteEl.textContent = note;
        row.appendChild(noteEl);
      }
      if (job.error) {
        // Partial cloud failure: one output succeeded, the other didn't.
        const err = document.createElement("div");
        err.className = "q-error";
        err.textContent = job.error;
        row.appendChild(err);
      }
    } else if (job.status === "failed") {
      const err = document.createElement("div");
      err.className = "q-error";
      err.textContent = job.error;
      row.appendChild(err);
    }

    queueEl.appendChild(row);
  }
}

function maybeShowDownloadAll() {
  const finished = jobs.filter((j) => j.status === "done" || j.status === "failed");
  const allDone = jobs.length > 0 && finished.length === jobs.length;
  const anyDone = jobs.some((j) => j.status === "done");
  downloadAllBtn.hidden = !(allDone && anyDone);
}

function baseName(fileName) {
  const i = fileName.lastIndexOf(".");
  return i === -1 ? fileName : fileName.slice(0, i);
}

function txtName(fileName) {
  return baseName(fileName) + ".txt";
}

/**
 * The downloadable files for a finished job. Both job kinds build the same
 * shape: the original transcript keeps today's `name.txt` naming, every
 * translated output carries its language code (`name.<lang>.txt`, and
 * `name.<lang>.srt`/`.vtt` for caption inputs).
 */
function outputFiles(job) {
  return job.outputs || [];
}

function downloadFile(name, text) {
  const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

async function downloadAllZip() {
  const done = jobs.filter((j) => j.status === "done");
  if (done.length === 0) return;

  const files = done.flatMap((j) =>
    outputFiles(j).map((f) => ({
      name: f.name,
      lastModified: new Date(),
      input: f.text,
    }))
  );

  const blob = await downloadZip(files).blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "stenodrop-transcripts.zip";
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

// ---------- event wiring ----------
pickFilesBtn.addEventListener("click", () => fileInput.click());
pickFolderBtn.addEventListener("click", () => folderInput.click());
fileInput.addEventListener("change", (e) => addFiles(e.target.files));
folderInput.addEventListener("change", (e) => addFiles(e.target.files));

downloadAllBtn.addEventListener("click", downloadAllZip);

["dragenter", "dragover"].forEach((evt) =>
  dropZone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropZone.classList.add("drag-over");
  })
);
["dragleave", "drop"].forEach((evt) =>
  dropZone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropZone.classList.remove("drag-over");
  })
);
dropZone.addEventListener("drop", async (e) => {
  const files = await collectDataTransferFiles(e.dataTransfer);
  addFiles(files);
});
