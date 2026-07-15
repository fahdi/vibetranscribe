// StenoDrop web app, main thread. Handles file/folder ingestion, audio
// decode + resample to 16kHz mono (Whisper's required input), the batch
// queue UI, and downloads (per-file .txt, all-as-.zip). All model work
// happens in worker.js so this thread never blocks.
import { downloadZip } from "https://cdn.jsdelivr.net/npm/client-zip@2.5.0/index.js";

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

const WHISPER_SAMPLE_RATE = 16000;

// ---------- DOM ----------
const dropZone = document.getElementById("drop-zone");
const fileInput = document.getElementById("file-input");
const folderInput = document.getElementById("folder-input");
const pickFilesBtn = document.getElementById("pick-files-btn");
const pickFolderBtn = document.getElementById("pick-folder-btn");
const languageSelect = document.getElementById("language-select");
const translateToggle = document.getElementById("translate-toggle");
const queueEl = document.getElementById("queue");
const queueSection = document.getElementById("queue-section");
const downloadAllBtn = document.getElementById("download-all-btn");
const modelStatus = document.getElementById("model-status");
const modelStatusText = document.getElementById("model-status-text");
const modelProgressBar = document.getElementById("model-progress-bar");
const deviceNote = document.getElementById("device-note");

// ---------- state ----------
/** @type {{id:string, file:File, status:string, text:string, error:string}[]} */
let jobs = [];
let jobSeq = 0;
let isProcessing = false;
let modelReady = false;
let downloadTotals = new Map(); // file -> {loaded, total}

// ---------- language picker ----------
for (const [code, name] of LANGUAGES) {
  const opt = document.createElement("option");
  opt.value = code;
  opt.textContent = name;
  if (code === "auto") opt.selected = true;
  languageSelect.appendChild(opt);
}

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
      handleDone(msg.jobId, msg.text);
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

function handleDone(jobId, text) {
  const job = jobs.find((j) => j.id === jobId);
  if (!job) return;
  job.status = "done";
  job.text = text;
  renderQueue();
  isProcessing = false;
  pump();
  maybeShowDownloadAll();
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
  const files = Array.from(fileList).filter((f) => AUDIO_EXTENSIONS.has(extOf(f.name)));
  if (files.length === 0) return;
  for (const file of files) {
    jobs.push({ id: String(jobSeq++), file, status: "queued", text: "", error: "" });
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
  next.status = "transcribing";
  renderQueue();

  decodeToPCM(next.file)
    .then((audio) => {
      worker.postMessage(
        {
          type: "transcribe",
          jobId: next.id,
          audio,
          language: languageSelect.value,
          translate: translateToggle.checked,
        },
        [audio.buffer]
      );
    })
    .catch((err) => {
      handleError(next.id, "Couldn't decode audio: " + (err.message || err));
    });
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
      const dlBtn = document.createElement("button");
      dlBtn.className = "btn-mini";
      dlBtn.textContent = "↓ .txt";
      dlBtn.addEventListener("click", () => downloadText(job));
      actions.appendChild(dlBtn);

      const copyBtn = document.createElement("button");
      copyBtn.className = "btn-mini";
      copyBtn.textContent = "Copy";
      copyBtn.addEventListener("click", () => {
        navigator.clipboard.writeText(job.text).then(() => {
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
      const transcript = document.createElement("div");
      transcript.className = "q-transcript";
      transcript.textContent = job.text || "(empty transcript)";
      row.appendChild(transcript);
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

function txtName(fileName) {
  const i = fileName.lastIndexOf(".");
  return (i === -1 ? fileName : fileName.slice(0, i)) + ".txt";
}

function downloadText(job) {
  const blob = new Blob([job.text], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = txtName(job.file.name);
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

async function downloadAllZip() {
  const done = jobs.filter((j) => j.status === "done");
  if (done.length === 0) return;

  const files = done.map((j) => ({
    name: txtName(j.file.name),
    lastModified: new Date(),
    input: j.text,
  }));

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
