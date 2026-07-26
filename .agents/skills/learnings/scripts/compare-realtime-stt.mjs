#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const defaultsDomain = "com.ethansk.VoiceInkPlusPlus";
const appSupportDirectory = `${process.env.HOME}/Library/Application Support/${defaultsDomain}`;
const historyDatabase = `${appSupportDirectory}/default.store`;
const dictionaryDatabase = `${appSupportDirectory}/dictionary.store`;

function usage() {
  console.log(`Usage: compare-realtime-stt.mjs [options]

Replays recent saved VoiceInk++ WAV files through AssemblyAI Universal-3.5 Pro
Realtime in max_accuracy mode and pairs each result with its original Soniox V5
streaming transcript.

Options:
  --limit <count>       Number of recent recordings to compare (default: 20)
  --output <path>       JSON report path (default: /private/tmp/...); resumes
                        successful rows when the file already exists
  --include-prompt      Include VoiceInk++'s current TranscriptionPrompt
  --dry-run             Inventory the corpus without contacting AssemblyAI
  --help                Show this help

The AssemblyAI key is read from VoiceInk++ local secure preferences and is never
printed, written to the report, passed in argv, or placed in the environment.`);
}

function parseArguments(argv) {
  const options = {
    limit: 20,
    output: `/private/tmp/voiceink-realtime-stt-comparison-${Date.now()}.json`,
    includePrompt: false,
    dryRun: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    switch (argument) {
      case "--limit": {
        const value = Number.parseInt(argv[index + 1] ?? "", 10);
        if (!Number.isInteger(value) || value < 1 || value > 100) {
          throw new Error("--limit must be an integer from 1 to 100");
        }
        options.limit = value;
        index += 1;
        break;
      }
      case "--output":
        options.output = argv[index + 1] ?? "";
        if (!options.output) {
          throw new Error("--output requires a path");
        }
        index += 1;
        break;
      case "--include-prompt":
        options.includePrompt = true;
        break;
      case "--dry-run":
        options.dryRun = true;
        break;
      case "--help":
        usage();
        process.exit(0);
      default:
        throw new Error(`Unknown argument: ${argument}`);
    }
  }

  return options;
}

function sqliteJSON(database, query) {
  const output = execFileSync("/usr/bin/sqlite3", ["-json", database, query], {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  }).trim();
  return output ? JSON.parse(output) : [];
}

function recentCorpus(limit) {
  const rows = sqliteJSON(
    historyDatabase,
    `SELECT
       Z_PK AS row_id,
       datetime(ZTIMESTAMP + 978307200, 'unixepoch', 'localtime') AS local_time,
       ZDURATION AS duration_seconds,
       ZTRANSCRIPTIONDURATION AS original_transcription_seconds,
       ZTRANSCRIPTIONMODELNAME AS original_model,
       ZAUDIOFILEURL AS audio_url,
       ZTEXT AS original_transcript
     FROM ZTRANSCRIPTION
     WHERE ZAUDIOFILEURL IS NOT NULL
       AND ZTEXT IS NOT NULL
       AND length(trim(ZTEXT)) > 0
       AND ZDURATION >= 0.5
     ORDER BY ZTIMESTAMP DESC
     LIMIT ${limit};`,
  );

  return rows.map((row) => {
    const audioPath = fileURLToPath(row.audio_url);
    if (!existsSync(audioPath)) {
      throw new Error(`Saved recording is missing: ${basename(audioPath)}`);
    }
    return {
      rowId: row.row_id,
      localTime: row.local_time,
      durationSeconds: row.duration_seconds,
      originalTranscriptionSeconds: row.original_transcription_seconds,
      originalModel: row.original_model,
      audioPath,
      audioFile: basename(audioPath),
      sonioxTranscript: row.original_transcript,
    };
  });
}

function vocabularyTerms() {
  return sqliteJSON(
    dictionaryDatabase,
    "SELECT ZWORD AS word FROM ZVOCABULARYWORD ORDER BY lower(ZWORD) LIMIT 100;",
  )
    .map(({ word }) => word?.trim())
    .filter(Boolean)
    .filter((word, index, all) => (
      word.length <= 50
      && word.split(/\s+/u).length <= 6
      && all.findIndex((other) => other.toLocaleLowerCase() === word.toLocaleLowerCase()) === index
    ));
}

function exportedDefaultsXML() {
  return execFileSync("/usr/bin/defaults", ["export", defaultsDomain, "-"], {
    maxBuffer: 16 * 1024 * 1024,
  });
}

function plistRawValue(key) {
  const result = spawnSync(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-"],
    {
      input: exportedDefaultsXML(),
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    },
  );
  if (result.status !== 0) {
    return null;
  }
  return result.stdout.trim();
}

function assemblyAIKey() {
  const base64Data = plistRawValue("LocalKeychain_assemblyAIAPIKey");
  if (!base64Data) {
    throw new Error(
      "AssemblyAI is not connected in VoiceInk++. Add and verify the key under "
      + "AI Models > Cloud > AssemblyAI, then rerun this script.",
    );
  }
  const key = Buffer.from(base64Data, "base64").toString("utf8").trim();
  if (!key) {
    throw new Error("The saved AssemblyAI key is empty");
  }
  return key;
}

function transcriptionPrompt() {
  return plistRawValue("TranscriptionPrompt")?.trim() ?? "";
}

function wavPCM16Mono16k(path) {
  const wav = readFileSync(path);
  if (wav.toString("ascii", 0, 4) !== "RIFF" || wav.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error(`${basename(path)} is not a RIFF/WAVE file`);
  }

  let offset = 12;
  let format = null;
  let pcm = null;
  while (offset + 8 <= wav.length) {
    const chunkName = wav.toString("ascii", offset, offset + 4);
    const chunkLength = wav.readUInt32LE(offset + 4);
    const chunkStart = offset + 8;
    const chunkEnd = chunkStart + chunkLength;
    if (chunkEnd > wav.length) {
      throw new Error(`${basename(path)} contains a truncated ${chunkName} chunk`);
    }

    if (chunkName === "fmt ") {
      format = {
        audioFormat: wav.readUInt16LE(chunkStart),
        channels: wav.readUInt16LE(chunkStart + 2),
        sampleRate: wav.readUInt32LE(chunkStart + 4),
        bitsPerSample: wav.readUInt16LE(chunkStart + 14),
      };
    } else if (chunkName === "data") {
      pcm = wav.subarray(chunkStart, chunkEnd);
    }

    offset = chunkEnd + (chunkLength % 2);
  }

  if (!format || !pcm) {
    throw new Error(`${basename(path)} is missing WAV format or audio data`);
  }
  if (
    format.audioFormat !== 1
    || format.channels !== 1
    || format.sampleRate !== 16_000
    || format.bitsPerSample !== 16
  ) {
    throw new Error(
      `${basename(path)} must be PCM16 mono 16 kHz; got ${JSON.stringify(format)}`,
    );
  }
  return pcm;
}

async function temporaryStreamingToken(apiKey, durationSeconds) {
  const maximumSessionDuration = Math.min(
    10_800,
    Math.max(60, Math.ceil(durationSeconds) + 60),
  );
  const tokenURL = new URL("https://streaming.assemblyai.com/v3/token");
  tokenURL.searchParams.set("expires_in_seconds", "60");
  tokenURL.searchParams.set(
    "max_session_duration_seconds",
    String(maximumSessionDuration),
  );

  const response = await fetch(tokenURL, {
    headers: { Authorization: apiKey },
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 500);
    throw new Error(`AssemblyAI token request failed (${response.status}): ${detail}`);
  }
  const payload = await response.json();
  if (typeof payload.token !== "string" || !payload.token) {
    throw new Error("AssemblyAI token response did not contain a token");
  }
  return payload.token;
}

function assemblyAIStreamingURL({ token, keyterms, prompt }) {
  const url = new URL("wss://streaming.assemblyai.com/v3/ws");
  url.searchParams.set("sample_rate", "16000");
  url.searchParams.set("encoding", "pcm_s16le");
  url.searchParams.set("speech_model", "universal-3-5-pro");
  url.searchParams.set("mode", "max_accuracy");
  url.searchParams.set("language_codes", JSON.stringify(["en"]));
  if (prompt) {
    url.searchParams.set("prompt", prompt);
  }
  if (keyterms.length > 0) {
    url.searchParams.set("keyterms_prompt", JSON.stringify(keyterms));
  }
  url.searchParams.set("token", token);
  return url;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function transcribeAssemblyAI({ apiKey, corpusItem, keyterms, prompt }) {
  const pcm = wavPCM16Mono16k(corpusItem.audioPath);
  const token = await temporaryStreamingToken(apiKey, corpusItem.durationSeconds);
  const websocketURL = assemblyAIStreamingURL({ token, keyterms, prompt });
  const connectionStartedAt = performance.now();
  const websocket = new WebSocket(websocketURL);
  let resolveClosed;
  const closed = new Promise((resolve) => {
    resolveClosed = resolve;
  });
  const committedTurns = new Map();
  const latestTurns = new Map();
  let beginAt = null;
  let terminateAt = null;
  let firstCommittedAfterTerminateAt = null;

  let resolveBegin;
  let rejectBegin;
  const begin = new Promise((resolve, reject) => {
    resolveBegin = resolve;
    rejectBegin = reject;
  });

  let resolveTermination;
  let rejectTermination;
  const termination = new Promise((resolve, reject) => {
    resolveTermination = resolve;
    rejectTermination = reject;
  });
  // A connection error can happen before `termination` is awaited. Mark the
  // rejection as observed while preserving the original promise for the normal
  // await path below.
  termination.catch(() => {});

  const timeout = setTimeout(() => {
    const error = new Error(`AssemblyAI timed out for ${corpusItem.audioFile}`);
    rejectBegin(error);
    rejectTermination(error);
    websocket.close();
  }, Math.ceil((corpusItem.durationSeconds + 90) * 1000));

  websocket.addEventListener("error", () => {
    const error = new Error(`AssemblyAI WebSocket failed for ${corpusItem.audioFile}`);
    rejectBegin(error);
    rejectTermination(error);
  });

  websocket.addEventListener("close", (event) => {
    resolveClosed();
    if (!beginAt) {
      rejectBegin(new Error(`AssemblyAI closed before Begin (${event.code})`));
    }
  });

  websocket.addEventListener("message", (event) => {
    if (typeof event.data !== "string") {
      return;
    }

    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }

    if (typeof message.error === "string") {
      const error = new Error(`AssemblyAI error: ${message.error}`);
      rejectBegin(error);
      rejectTermination(error);
      return;
    }

    if (message.type === "Begin") {
      beginAt = performance.now();
      resolveBegin();
      return;
    }

    if (message.type === "Turn" && typeof message.transcript === "string") {
      const order = Number.isInteger(message.turn_order)
        ? message.turn_order
        : latestTurns.size;
      latestTurns.set(order, message.transcript);
      if (message.end_of_turn === true && message.transcript.trim()) {
        committedTurns.set(order, message.transcript.trim());
        if (terminateAt !== null && firstCommittedAfterTerminateAt === null) {
          firstCommittedAfterTerminateAt = performance.now();
        }
      }
      return;
    }

    if (message.type === "Termination") {
      resolveTermination(performance.now());
    }
  });

  try {
    await begin;

    // VoiceInk++ records 16 kHz mono PCM16. Replay 100 ms (3,200-byte)
    // chunks at real-time pace because AssemblyAI explicitly rejects audio
    // streamed faster than real time.
    const chunkBytes = 3_200;
    for (let offset = 0; offset < pcm.length; offset += chunkBytes) {
      websocket.send(pcm.subarray(offset, Math.min(offset + chunkBytes, pcm.length)));
      const expectedElapsed = ((offset + chunkBytes) / 32_000) * 1000;
      const actualElapsed = performance.now() - beginAt;
      if (expectedElapsed > actualElapsed) {
        await delay(expectedElapsed - actualElapsed);
      }
    }

    terminateAt = performance.now();
    websocket.send(JSON.stringify({ type: "Terminate" }));
    const terminatedAt = await termination;

    const finalTurns = committedTurns.size > 0 ? committedTurns : latestTurns;
    const transcript = [...finalTurns.entries()]
      .sort(([left], [right]) => left - right)
      .map(([, text]) => text.trim())
      .filter(Boolean)
      .join(" ")
      .trim();

    return {
      transcript,
      connectionMilliseconds: Math.round(beginAt - connectionStartedAt),
      stopToFirstCommittedMilliseconds: firstCommittedAfterTerminateAt === null
        ? null
        : Math.round(firstCommittedAfterTerminateAt - terminateAt),
      stopToTerminationMilliseconds: Math.round(terminatedAt - terminateAt),
    };
  } finally {
    clearTimeout(timeout);
    if (websocket.readyState < WebSocket.CLOSING) {
      websocket.close();
    }
    // AssemblyAI enforces concurrent-session limits. Wait briefly for the
    // provider to observe each closed session before opening the next one.
    await Promise.race([closed, delay(1_000)]);
  }
}

async function transcribeAssemblyAIWithContentionBackoff(arguments_) {
  const maximumAttempts = 8;

  for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
    try {
      return await transcribeAssemblyAI(arguments_);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!/too many concurrent sessions/iu.test(message) || attempt === maximumAttempts) {
        throw error;
      }

      const backoffMilliseconds = Math.min(30_000, attempt * 5_000);
      process.stderr.write(
        `AssemblyAI is busy with another live session; yielding for `
        + `${backoffMilliseconds / 1000}s before retry ${attempt + 1}/${maximumAttempts}.\n`,
      );
      await delay(backoffMilliseconds);
    }
  }

  throw new Error("AssemblyAI contention retry loop ended unexpectedly");
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const corpus = recentCorpus(options.limit);
  const keyterms = vocabularyTerms();
  const prompt = options.includePrompt ? transcriptionPrompt() : "";

  if (options.dryRun) {
    console.log(JSON.stringify({
      count: corpus.length,
      totalDurationSeconds: corpus.reduce((sum, item) => sum + item.durationSeconds, 0),
      keyterms,
      includesPrompt: Boolean(prompt),
      corpus: corpus.map(({ audioPath: _audioPath, ...item }) => item),
    }, null, 2));
    return;
  }

  const apiKey = assemblyAIKey();
  let startedAt = new Date().toISOString();
  const priorComparisons = new Map();
  if (existsSync(options.output)) {
    const priorReport = JSON.parse(readFileSync(options.output, "utf8"));
    if (
      priorReport?.configuration?.assemblyAIModel !== "universal-3-5-pro"
      || priorReport?.configuration?.assemblyAIMode !== "max_accuracy"
      || priorReport?.configuration?.promptIncluded !== Boolean(prompt)
    ) {
      throw new Error("Existing report configuration does not match this run");
    }
    startedAt = priorReport.startedAt ?? startedAt;
    for (const comparison of priorReport.comparisons ?? []) {
      if (
        Number.isInteger(comparison.rowId)
        && typeof comparison.assemblyAI?.transcript === "string"
        && comparison.assemblyAI.transcript.trim()
      ) {
        priorComparisons.set(comparison.rowId, comparison);
      }
    }
  }

  const comparisons = [];

  for (let index = 0; index < corpus.length; index += 1) {
    const item = corpus[index];
    const prior = priorComparisons.get(item.rowId);
    if (prior) {
      process.stderr.write(
        `[${index + 1}/${corpus.length}] reused ${item.audioFile} `
        + `(${item.durationSeconds.toFixed(1)}s)\n`,
      );
      comparisons.push(prior);
      continue;
    }

    process.stderr.write(
      `[${index + 1}/${corpus.length}] ${item.audioFile} `
      + `(${item.durationSeconds.toFixed(1)}s)\n`,
    );
    try {
      const assemblyAI = await transcribeAssemblyAIWithContentionBackoff({
        apiKey,
        corpusItem: item,
        keyterms,
        prompt,
      });
      comparisons.push({
        ...item,
        audioPath: undefined,
        assemblyAI,
      });
    } catch (error) {
      comparisons.push({
        ...item,
        audioPath: undefined,
        assemblyAI: {
          error: error instanceof Error ? error.message : String(error),
        },
      });
      throw error;
    } finally {
      writeFileSync(options.output, `${JSON.stringify({
        schemaVersion: 1,
        startedAt,
        updatedAt: new Date().toISOString(),
        configuration: {
          assemblyAIModel: "universal-3-5-pro",
          assemblyAIMode: "max_accuracy",
          languageCodes: ["en"],
          keyterms,
          promptIncluded: Boolean(prompt),
        },
        comparisons,
      }, null, 2)}\n`, { mode: 0o600 });
    }
  }

  console.log(options.output);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
