// POST /transcribe — proxy from the iOS app to the Whisper Vertex AI endpoint.
//
// Request:  multipart/form-data with `audio` (file), optional `terms` (newline-separated vocabulary)
//           and `language` fields; header `Authorization: Bearer <WHISPER_POC_TOKEN>`.
// Response: { "text": <normalized>, "rawText": <Whisper output>, "prompt": "...",
//             "latencyMs": <server round trip>, "inferenceMs": <GPU time>, "duration": <s> }

const functions = require("@google-cloud/functions-framework");
const Busboy = require("busboy");
const { GoogleAuth } = require("google-auth-library");

const { PROJECT_ID, REGION, ENDPOINT_ID, WHISPER_POC_TOKEN } = process.env;
const PREDICT_URL =
  `https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}` +
  `/locations/${REGION}/endpoints/${ENDPOINT_ID}:predict`;

// Vertex online prediction rejects request bodies over 1.5 MB; base64 adds ~33%.
const MAX_AUDIO_BYTES = 1_000_000;

const auth = new GoogleAuth({ scopes: "https://www.googleapis.com/auth/cloud-platform" });

function parseMultipart(req) {
  return new Promise((resolve, reject) => {
    const fields = {};
    let audio = null;
    const busboy = Busboy({ headers: req.headers, limits: { fileSize: MAX_AUDIO_BYTES + 1 } });
    busboy.on("field", (name, value) => (fields[name] = value));
    busboy.on("file", (name, stream) => {
      const chunks = [];
      stream.on("data", (chunk) => chunks.push(chunk));
      stream.on("end", () => {
        if (name === "audio") audio = Buffer.concat(chunks);
      });
    });
    busboy.on("finish", () => resolve({ fields, audio }));
    busboy.on("error", reject);
    busboy.end(req.rawBody);
  });
}

functions.http("transcribe", async (req, res) => {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (req.get("authorization") !== `Bearer ${WHISPER_POC_TOKEN}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  const start = Date.now();
  try {
    const { fields, audio } = await parseMultipart(req);
    if (!audio?.length) return res.status(400).json({ error: "Missing `audio` file" });
    if (audio.length > MAX_AUDIO_BYTES) {
      return res.status(413).json({ error: "Recording too long for the POC (~4 min max)" });
    }

    const client = await auth.getClient();
    const response = await client.request({
      url: PREDICT_URL,
      method: "POST",
      data: {
        instances: [{
          audio_b64: audio.toString("base64"),
          terms: (fields.terms || "").split("\n").filter((term) => term.trim()),
          language: fields.language || "en",
        }],
      },
    });

    const prediction = response.data.predictions[0];
    res.json({
      text: prediction.text,
      rawText: prediction.raw_text,
      prompt: prediction.prompt,
      latencyMs: Date.now() - start,
      inferenceMs: prediction.inference_ms,
      duration: prediction.duration,
    });
  } catch (error) {
    console.error(error.response?.data ?? error);
    const status = error.response?.status ?? 500;
    res.status(status === 404 || status === 400 ? 502 : status).json({
      error: error.response?.data?.error?.message ?? error.message,
    });
  }
});
