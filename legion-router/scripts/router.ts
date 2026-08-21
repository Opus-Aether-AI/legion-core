/**
 * Legion Router — multi-model metering proxy (loopback :8082)
 *
 * Routes Claude Code API requests by model name and meters token usage + cost:
 * - Models matching MINIMAX_MODELS → MiniMax API (translation-free; Anthropic-compatible)
 * - Everything else → Anthropic API (client auth passes through when no proxy key)
 * Codex is NOT routed here (codex exec is an agent, not an endpoint) — the
 * legion-delegate CLI runs it out-of-band and POSTs usage to /ingest, so Codex cost
 * shows next to Claude on /stats.
 *
 * OPT-IN: only traffic you explicitly point at it is routed. Start it, then set
 *   ANTHROPIC_BASE_URL=http://127.0.0.1:8082
 * for the session/runner you want metered. The router never exports this itself.
 *
 * Usage: bun run legion-router/scripts/router.ts   (or: legion-router start)
 */

// Inline env helpers — standalone script, no monorepo imports
function _optionalEnv(name: string, d: string): string { return process.env[name] || d; }
function _optionalEnvInt(name: string, d: number): number {
	const raw = process.env[name];
	if (!raw) return d;
	const n = Number.parseInt(raw, 10);
	return Number.isNaN(n) ? d : n;
}
// Coerce any external value to a finite, non-negative integer (token counts).
// Guards stats against a malformed payload poisoning totals with NaN/Infinity/<0.
function nonNegInt(x: unknown): number {
	const n = Number(x ?? 0);
	return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
}

const PORT = _optionalEnvInt("ROUTER_PORT", 8082);
const UPSTREAM_TIMEOUT = _optionalEnvInt("UPSTREAM_TIMEOUT_MS", 120_000);
const STREAM_UPSTREAM_TIMEOUT = _optionalEnvInt("STREAM_UPSTREAM_TIMEOUT_MS", 0);
const LOG_FORMAT = _optionalEnv("LOG_FORMAT", "json");
const AUTO_TIER = process.env.AUTO_TIER === "true"; // Enable automatic model tiering by request size
const MODEL_CONFIG_FILE = _optionalEnv("LEGION_MODELS_FILE", `${import.meta.dir}/../config/models.toml`);

// ── Structured logging ──────────────────────────────────────────────
function log(level: "info" | "warn" | "error", msg: string, meta?: Record<string, unknown>) {
	if (LOG_FORMAT === "json") {
		const entry: Record<string, unknown> = {
			ts: new Date().toISOString(),
			level,
			msg,
		};
		if (meta) entry.meta = meta;
		console.log(JSON.stringify(entry));
	} else {
		const metaStr = meta ? ` ${JSON.stringify(meta)}` : "";
		console.log(`[router] [${level}] ${msg}${metaStr}`);
	}
}

// The catalog has ONE reader: legion-route. This file used to hand-roll a second
// TOML parser because it is a standalone bun script with no monorepo imports,
// which left models.toml with two parsers free to drift -- and the drift is
// silent, because a role this parser fails to see simply resolves to "" and the
// request falls through to a default. The canonical reader is invoked once at
// boot instead; a proxy that cannot read its own catalog should say so rather
// than route on a half-parsed one.
//
// Deliberately not a bare `bun` import of the Python: this is a subprocess
// boundary, not a module boundary, and keeping it explicit is what allows
// legion-route to stay the single source of truth for every consumer.
async function loadModelCatalog(path: string): Promise<Record<string, string>> {
	const reader = `${import.meta.dir}/legion-route.py`;
	try {
		const proc = Bun.spawn(["python3", reader, "--models-json", "--models-file", path], {
			stdout: "pipe",
			stderr: "pipe",
		});
		const [out, err, code] = await Promise.all([
			new Response(proc.stdout).text(),
			new Response(proc.stderr).text(),
			proc.exited,
		]);
		if (code !== 0) {
			log("warn", "model catalog unavailable", { path, exit: code, error: err.trim() });
			return {};
		}
		const parsed = JSON.parse(out);
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			log("warn", "model catalog is not an object", { path });
			return {};
		}
		// Keep only string values. The canonical reader returns the catalog as
		// TOML declares it, so a malformed entry (`role = 42`) would otherwise
		// arrive typed as a string and be handed to an upstream as a model id.
		const catalog: Record<string, string> = {};
		for (const [role, value] of Object.entries(parsed as Record<string, unknown>)) {
			if (typeof value === "string" && value) catalog[role] = value;
			else log("warn", "ignoring non-string model role", { role, path });
		}
		return catalog;
	} catch (err) {
		log("warn", "model catalog unavailable", { path, error: String(err) });
		return {};
	}
}

const MODEL_CATALOG = await loadModelCatalog(MODEL_CONFIG_FILE);
// An empty catalog is not fatal -- every lookup falls through to a default -- but
// it is a silent degradation, which is the failure this file's second TOML
// parser used to cause. Say the count out loud at boot so "routing on nothing"
// is visible in the log rather than inferred from odd model choices later.
if (Object.keys(MODEL_CATALOG).length === 0) {
	log("warn", "model catalog is empty; every model role will fall through to its default", {
		path: MODEL_CONFIG_FILE,
	});
} else {
	log("info", "model catalog loaded", {
		path: MODEL_CONFIG_FILE,
		roles: Object.keys(MODEL_CATALOG).length,
	});
}
function configuredModel(ref: string): string {
	return MODEL_CATALOG[ref] ?? "";
}

// ── Upstream configs ────────────────────────────────────────────────
// Keep router upstream overrides distinct from the client-facing
// ANTHROPIC_BASE_URL. The latter is intentionally set to this proxy by callers;
// treating it as our upstream would recursively proxy the request back to self.
const ANTHROPIC_BASE = _optionalEnv("LEGION_ANTHROPIC_UPSTREAM_URL", "https://api.anthropic.com");
const MINIMAX_BASE = _optionalEnv("LEGION_MINIMAX_UPSTREAM_URL", "https://api.minimax.io/anthropic");
const OLLAMA_BASE = _optionalEnv("OLLAMA_BASE_URL", "http://localhost:11434");

function targetsRouter(base: string): boolean {
	try {
		const target = new URL(base);
		const host = target.hostname.toLowerCase();
		const loopback = host === "localhost" || host === "127.0.0.1"
			|| host === "0.0.0.0" || host === "[::1]" || host === "::1";
		const port = Number.parseInt(target.port || (target.protocol === "https:" ? "443" : "80"), 10);
		return loopback && port === PORT;
	} catch {
		return false;
	}
}

if (targetsRouter(ANTHROPIC_BASE) || targetsRouter(MINIMAX_BASE) || targetsRouter(OLLAMA_BASE)) {
	throw new Error("router upstream URL must not target the Legion router itself");
}

// Both optional — the Legion router starts even with no keys. With no Anthropic
// key, claude-* requests pass through the client's own auth header; with no
// MiniMax token, minimax-* models fall back to Anthropic. The /ingest sink and
// /stats work regardless, so the router is useful purely as a meter.
const ANTHROPIC_KEY = _optionalEnv("ANTHROPIC_API_KEY", "");
const MINIMAX_TOKEN = _optionalEnv("MINIMAX_AUTH_TOKEN", "");

// Models to route through MiniMax (case-insensitive substring match)
const MINIMAX_MODELS = _optionalEnv("MINIMAX_MODELS", "MiniMax").split(",").map((m) => m.trim().toLowerCase());

// Models to route through local Ollama (prefix "local:" in model map)
// e.g. OLLAMA_MODEL_MAP="local:deepseek-coder-v2,local:qwen2.5-coder"
const OLLAMA_MODELS = (process.env.OLLAMA_MODELS || "").split(",").map((m) => m.trim().toLowerCase()).filter(Boolean);

// Optional: lock specific Claude Code model tiers to MiniMax model IDs
// e.g. MINIMAX_MODEL_MAP="small:your-minimax-model,standard:your-minimax-model"
const MODEL_MAP = new Map<string, string>();
for (const entry of (process.env.MINIMAX_MODEL_MAP || "").split(",").filter(Boolean)) {
	const [from, to] = entry.split(":");
	if (from && to) MODEL_MAP.set(from.trim().toLowerCase(), to.trim());
}

// ── Circuit breaker ─────────────────────────────────────────────────
const CIRCUIT_BREAKER_THRESHOLD = _optionalEnvInt("CIRCUIT_BREAKER_THRESHOLD", 3);
const CIRCUIT_BREAKER_COOLDOWN_MS = _optionalEnvInt("CIRCUIT_BREAKER_COOLDOWN_MS", 300_000);

let minimaxFailCount = 0;
let minimaxCircuitOpenUntil = 0;

// ── Per-model cost (single source of truth: ../config/costs.json) ───
interface CostRow { match: string; input: number; output: number; cache_read: number; cache_write: number }
interface CostTable { models: CostRow[]; default: Omit<CostRow, "match"> }
let COST_TABLE: CostTable | null = null;
try {
	const p = process.env.LEGION_COSTS_FILE || `${import.meta.dir}/../config/costs.json`;
	COST_TABLE = JSON.parse(await Bun.file(p).text()) as CostTable;
} catch {
	COST_TABLE = null; // missing/invalid table -> cost computes as 0, never errors
}

function costForModel(model: string, input: number, output: number, cacheRead = 0, cacheWrite = 0): number {
	if (!COST_TABLE) return 0;
	const m = model.toLowerCase();
	const p = COST_TABLE.models.find((r) => m.includes(r.match)) ?? COST_TABLE.default;
	const usd = (input / 1e6) * (p.input ?? 0) + (output / 1e6) * (p.output ?? 0)
		+ (cacheRead / 1e6) * (p.cache_read ?? 0) + (cacheWrite / 1e6) * (p.cache_write ?? 0);
	return Math.round(usd * 1e6) / 1e6;
}

// ── Usage tracking ─────────────────────────────────────────────────
interface UsageEntry {
	ts: string;
	model: string;
	upstream: string;
	inputTokens: number;
	outputTokens: number;
	cacheCreationTokens: number;
	cacheReadTokens: number;
	costUsd: number;
	status: number;
}

type Agg = { requests: number; inputTokens: number; outputTokens: number; costUsd: number };

const usageStats = {
	totalRequests: 0,
	totalInputTokens: 0,
	totalOutputTokens: 0,
	totalCacheCreationTokens: 0,
	totalCacheReadTokens: 0,
	totalCostUsd: 0,
	byModel: new Map<string, Agg>(),
	byUpstream: new Map<string, Agg>(),
	startedAt: new Date().toISOString(),
	recentEntries: [] as UsageEntry[],
};

const USAGE_LOG_DIR = `${process.env.HOME}/.claude/logs/costs`;
const MAX_RECENT_ENTRIES = 100;

// Fold one usage record (proxied request OR /ingest'd out-of-band run) into stats.
function applyUsage(args: {
	model: string;
	upstreamName: string;
	status: number;
	inputTokens: number;
	outputTokens: number;
	cacheCreation: number;
	cacheRead: number;
	costUsd: number;
}) {
	const { model, upstreamName, status, inputTokens, outputTokens, cacheCreation, cacheRead, costUsd } = args;

	usageStats.totalRequests++;
	usageStats.totalInputTokens += inputTokens;
	usageStats.totalOutputTokens += outputTokens;
	usageStats.totalCacheCreationTokens += cacheCreation;
	usageStats.totalCacheReadTokens += cacheRead;
	usageStats.totalCostUsd = Math.round((usageStats.totalCostUsd + costUsd) * 1e6) / 1e6;

	const ms = usageStats.byModel.get(model) ?? { requests: 0, inputTokens: 0, outputTokens: 0, costUsd: 0 };
	ms.requests++; ms.inputTokens += inputTokens; ms.outputTokens += outputTokens;
	ms.costUsd = Math.round((ms.costUsd + costUsd) * 1e6) / 1e6;
	usageStats.byModel.set(model, ms);

	const us = usageStats.byUpstream.get(upstreamName) ?? { requests: 0, inputTokens: 0, outputTokens: 0, costUsd: 0 };
	us.requests++; us.inputTokens += inputTokens; us.outputTokens += outputTokens;
	us.costUsd = Math.round((us.costUsd + costUsd) * 1e6) / 1e6;
	usageStats.byUpstream.set(upstreamName, us);

	const entry: UsageEntry = {
		ts: new Date().toISOString(),
		model, upstream: upstreamName,
		inputTokens, outputTokens,
		cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead,
		costUsd, status,
	};
	usageStats.recentEntries.push(entry);
	if (usageStats.recentEntries.length > MAX_RECENT_ENTRIES) usageStats.recentEntries.shift();
	appendCostLog(entry).catch(() => { /* non-critical */ });
}

function recordUsage(model: string, upstream: string, status: number, usage?: Record<string, unknown>) {
	const inputTokens = nonNegInt(usage?.input_tokens);
	const outputTokens = nonNegInt(usage?.output_tokens);
	const cacheCreation = nonNegInt(usage?.cache_creation_input_tokens);
	const cacheRead = nonNegInt(usage?.cache_read_input_tokens);

	let upstreamName = "anthropic";
	if (upstream === MINIMAX_BASE) upstreamName = "minimax";
	else if (upstream === OLLAMA_BASE) upstreamName = "ollama";

	applyUsage({
		model, upstreamName, status,
		inputTokens, outputTokens, cacheCreation, cacheRead,
		costUsd: costForModel(model, inputTokens, outputTokens, cacheRead, cacheCreation),
	});
}

// Fold an out-of-band usage record posted to /ingest (codex/GPT delegate runs,
// which can't flow through the HTTP hot path). Maps codex's OpenAI-shaped usage
// (input_tokens incl. cached, cached_input_tokens, output_tokens, reasoning_output_tokens).
export function ingestUsage(rec: Record<string, unknown>): { ok: boolean; costUsd: number } {
	const model = String(rec.model ?? "unknown");
	const upstreamName = String(rec.upstream ?? "codex");
	const status = Number(rec.status ?? 0);
	const u = (rec.usage ?? {}) as Record<string, unknown>;
	const rawInput = nonNegInt(u.input_tokens);
	const cachedInput = nonNegInt(u.cached_input_tokens ?? u.cache_read_input_tokens);
	const billedInput = Math.max(0, rawInput - cachedInput);
	const outputTokens = nonNegInt(u.output_tokens) + nonNegInt(u.reasoning_output_tokens);
	const providedCost = Number(rec.cost_usd);
	const costUsd = Number.isFinite(providedCost) && providedCost >= 0
		? providedCost
		: costForModel(model, billedInput, outputTokens, cachedInput, 0);

	applyUsage({
		model, upstreamName, status,
		inputTokens: billedInput, outputTokens,
		cacheCreation: 0, cacheRead: cachedInput,
		costUsd,
	});
	return { ok: true, costUsd };
}

async function appendCostLog(entry: UsageEntry) {
	const { mkdir, appendFile } = await import("node:fs/promises");
	await mkdir(USAGE_LOG_DIR, { recursive: true });
	const date = entry.ts.slice(0, 10);
	const line = `${JSON.stringify(entry)}\n`;
	// O_APPEND — atomic for small lines, so concurrent writers (proxied requests
	// + out-of-band /ingest) don't clobber each other (unlike read-modify-write).
	await appendFile(`${USAGE_LOG_DIR}/${date}.jsonl`, line);
}

// Extract usage from a non-streaming API response body
function extractUsageFromBody(body: string): Record<string, unknown> | undefined {
	try {
		const parsed = JSON.parse(body);
		return parsed?.usage as Record<string, unknown> | undefined;
	} catch {
		return undefined;
	}
}

// Parse a single SSE data line, merge usage, and retain the terminal marker.
// Some HTTP clients expose an upstream socket close as a clean body EOF, so a
// successful Anthropic-compatible stream is complete only after message_stop
// (or the equivalent [DONE] marker used by a few compatible providers).
function mergeSSEUsage(
	data: string,
	acc: Record<string, unknown>,
): { usage: Record<string, unknown>; terminal: boolean } {
	if (data === "[DONE]") return { usage: acc, terminal: true };
	try {
		const parsed = JSON.parse(data);
		// message_start carries input_tokens
		if (parsed.type === "message_start" && parsed.message?.usage) {
			return {
				usage: { ...acc, ...(parsed.message.usage as Record<string, unknown>) },
				terminal: false,
			};
		}
		// message_delta carries output_tokens
		if (parsed.usage) {
			return {
				usage: { ...acc, ...(parsed.usage as Record<string, unknown>) },
				terminal: parsed.type === "message_stop",
			};
		}
		return { usage: acc, terminal: parsed.type === "message_stop" };
	} catch {
		// Not valid JSON — skip
	}
	return { usage: acc, terminal: false };
}

function parseSSEUsageChunk(
	text: string,
	acc: Record<string, unknown>,
): { buffer: string; usage: Record<string, unknown>; terminal: boolean } {
	let usage = acc;
	let terminal = false;
	const lines = text.split("\n");
	const buffer = lines.pop() ?? "";
	for (const line of lines) {
		if (line.startsWith("data:")) {
			// SSE permits both `data: value` and `data:value`. Strip the field
			// name first, then tolerate the optional post-colon whitespace.
			const parsed = mergeSSEUsage(line.slice(5).trimStart(), usage);
			usage = parsed.usage;
			terminal ||= parsed.terminal;
		}
	}
	return { buffer, usage, terminal };
}

// Forward an SSE response with one reader while metering usage from the same
// chunks. Avoid ReadableStream.tee(): under high concurrency tee doubles the
// buffering/backpressure surface and has been observed to make long subagent
// streams fail with closed sockets.
function meteredSSEStream(
	stream: ReadableStream<Uint8Array>,
	model: string,
	upstream: string,
	status: number,
): ReadableStream<Uint8Array> {
	const decoder = new TextDecoder();
	const encoder = new TextEncoder();
	const reader = stream.getReader();
	let buffer = "";
	let usage: Record<string, unknown> = {};
	let terminalSeen = false;
	let recorded = false;
	let released = false;

	const record = (finalStatus: number) => {
		if (recorded) return;
		recorded = true;
		recordUsage(model, upstream, finalStatus, Object.keys(usage).length > 0 ? usage : undefined);
	};
	const release = () => {
		if (released) return;
		released = true;
		reader.releaseLock();
	};
	const fail = (
		controller: ReadableStreamDefaultController<Uint8Array>,
		err: unknown,
	) => {
		log("warn", "upstream stream interrupted", { model, upstream, error: String(err) });
		record(599);
		release();
		try {
			controller.enqueue(encoder.encode(`event: error\ndata: ${JSON.stringify({
				type: "error",
				error: { type: "upstream_stream_error", message: "upstream stream interrupted" },
			})}\n\n`));
			controller.close();
		} catch {
			try { controller.error(err); } catch { /* already closed */ }
		}
	};
	const finish = (controller: ReadableStreamDefaultController<Uint8Array>) => {
		const tail = decoder.decode();
		if (tail || buffer) {
			const parsed = parseSSEUsageChunk(`${buffer}${tail}\n`, usage);
			usage = parsed.usage;
			terminalSeen ||= parsed.terminal;
		}
		if (status >= 200 && status < 300 && !terminalSeen) {
			fail(controller, new Error("upstream stream ended before a terminal event"));
			return;
		}
		record(status);
		release();
		controller.close();
	};

	return new ReadableStream<Uint8Array>({
		async pull(controller) {
			try {
				const { done, value } = await reader.read();
				if (done) {
					finish(controller);
					return;
				}
				if (!value) return;
				const parsed = parseSSEUsageChunk(buffer + decoder.decode(value, { stream: true }), usage);
				buffer = parsed.buffer;
				usage = parsed.usage;
				terminalSeen ||= parsed.terminal;
				controller.enqueue(value);
			} catch (err) {
				fail(controller, err);
			}
		},
		async cancel(reason) {
			record(499);
			try {
				await reader.cancel(reason);
			} finally {
				release();
			}
		},
	});
}

async function meteredUpstreamResponse(
	upstreamRes: Response,
	model: string,
	upstream: string,
	isStream: boolean,
): Promise<Response> {
	const responseHeaders = new Headers(upstreamRes.headers);
	responseHeaders.delete("content-encoding");
	responseHeaders.delete("content-length");

	if (!isStream && upstreamRes.body) {
		const body = await upstreamRes.text();
		recordUsage(model, upstream, upstreamRes.status, extractUsageFromBody(body));
		return new Response(body, {
			status: upstreamRes.status,
			statusText: upstreamRes.statusText,
			headers: responseHeaders,
		});
	}
	if (isStream && upstreamRes.body) {
		return new Response(
			meteredSSEStream(upstreamRes.body, model, upstream, upstreamRes.status),
			{
				status: upstreamRes.status,
				statusText: upstreamRes.statusText,
				headers: responseHeaders,
			},
		);
	}

	recordUsage(model, upstream, upstreamRes.status);
	return new Response(null, {
		status: upstreamRes.status,
		statusText: upstreamRes.statusText,
		headers: responseHeaders,
	});
}

function upstreamFetchTimeout(isStream: boolean): { signal?: AbortSignal; clearAfterHeaders: () => void } {
	if (!isStream || STREAM_UPSTREAM_TIMEOUT > 0) {
		const timeout = isStream ? STREAM_UPSTREAM_TIMEOUT : UPSTREAM_TIMEOUT;
		return {
			signal: timeout > 0 ? AbortSignal.timeout(timeout) : undefined,
			clearAfterHeaders: () => {},
		};
	}

	if (UPSTREAM_TIMEOUT <= 0) return { clearAfterHeaders: () => {} };
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT);
	return {
		signal: controller.signal,
		clearAfterHeaders: () => clearTimeout(timer),
	};
}

function isCircuitOpen(): boolean {
	if (minimaxCircuitOpenUntil === 0) return false;
	if (Date.now() >= minimaxCircuitOpenUntil) {
		minimaxCircuitOpenUntil = 0;
		minimaxFailCount = 0;
		log("info", "Circuit half-open: testing MiniMax");
		return false;
	}
	return true;
}

function recordMiniMaxFailure() {
	minimaxFailCount++;
	if (minimaxFailCount >= CIRCUIT_BREAKER_THRESHOLD) {
		minimaxCircuitOpenUntil = Date.now() + CIRCUIT_BREAKER_COOLDOWN_MS;
		log("warn", "Circuit OPEN", { failCount: minimaxFailCount, cooldownSecs: CIRCUIT_BREAKER_COOLDOWN_MS / 1000 });
	}
}

function recordMiniMaxSuccess() {
	minimaxFailCount = 0;
	minimaxCircuitOpenUntil = 0;
}

// ── Helpers ─────────────────────────────────────────────────────────
function isMiniMaxModel(model: string): boolean {
	const lower = model.toLowerCase();
	return MINIMAX_MODELS.some((m) => lower.includes(m));
}

function isOllamaModel(model: string): boolean {
	const lower = model.toLowerCase();
	return OLLAMA_MODELS.some((m) => lower.includes(m));
}

interface RouteResult {
	model: string;
	originalModel: string;
	upstream: string;
	authHeader: Record<string, string>;
}

function resolveModel(model: string): RouteResult {
	// Circuit breaker: if open, skip MiniMax entirely
	if (isCircuitOpen()) {
		log("info", "Circuit open — routing to Anthropic", { model });
		return {
			model,
			originalModel: model,
			upstream: ANTHROPIC_BASE,
			authHeader: { "x-api-key": ANTHROPIC_KEY },
		};
	}

	// Check an explicit model map first (e.g. "small:your-provider-model").
	for (const [pattern, replacement] of MODEL_MAP) {
		if (model.toLowerCase().includes(pattern)) {
			// "ollama/" prefix routes to local Ollama
			if (replacement.startsWith("ollama/")) {
				return {
					model: replacement.slice(7),
					originalModel: model,
					upstream: OLLAMA_BASE,
					authHeader: {},
				};
			}
			if (MINIMAX_TOKEN) {
				return {
					model: replacement,
					originalModel: model,
					upstream: MINIMAX_BASE,
					authHeader: { Authorization: `Bearer ${MINIMAX_TOKEN}` },
				};
			}
			// mapped to MiniMax but no token configured -> fall through to Anthropic
			break;
		}
	}

	// Check if model name itself is a MiniMax model (only if we have a token;
	// otherwise fall through to Anthropic rather than sending an empty Bearer).
	if (isMiniMaxModel(model) && MINIMAX_TOKEN) {
		return {
			model,
			originalModel: model,
			upstream: MINIMAX_BASE,
			authHeader: { Authorization: `Bearer ${MINIMAX_TOKEN}` },
		};
	}

	// Check if model should route to local Ollama
	if (isOllamaModel(model)) {
		return {
			model,
			originalModel: model,
			upstream: OLLAMA_BASE,
			authHeader: {},
		};
	}

	// Default: Anthropic
	return {
		model,
		originalModel: model,
		upstream: ANTHROPIC_BASE,
		authHeader: { "x-api-key": ANTHROPIC_KEY },
	};
}

function buildHeaders(req: Request, authHeader: Record<string, string>, upstream: string): Headers {
	const headers = new Headers(req.headers);

	// Remove hop-by-hop and proxy-specific headers that must not be forwarded
	headers.delete("host");
	headers.delete("connection");
	headers.delete("transfer-encoding");
	headers.delete("keep-alive");
	headers.delete("upgrade");
	// Body was decoded by req.text(), so content-encoding/content-length are stale
	headers.delete("content-encoding");
	headers.delete("content-length");

	// Enable prompt caching for Anthropic requests (reduces costs up to 90% for repeated prefixes)
	if (upstream === ANTHROPIC_BASE) {
		const beta = headers.get("anthropic-beta") ?? "";
		if (!beta.includes("prompt-caching")) {
			const newBeta = beta ? `${beta},prompt-caching-2024-07-31` : "prompt-caching-2024-07-31";
			headers.set("anthropic-beta", newBeta);
		}
	}

	// For Anthropic: pass through ALL client auth headers if proxy has no key configured
	// Claude Code may use x-api-key OR Authorization: Bearer (OAuth) depending on login method
	if (upstream === ANTHROPIC_BASE && !ANTHROPIC_KEY) {
		// Keep original x-api-key AND authorization from the client — don't touch auth headers
	} else {
		// Replace auth headers with proxy's own credentials
		headers.delete("x-api-key");
		headers.delete("authorization");
		for (const [k, v] of Object.entries(authHeader)) {
			headers.set(k, v);
		}
	}
	return headers;
}

// ── Request parsing ─────────────────────────────────────────────────
interface ParsedRequest {
	body: string | null;
	parsedBody: Record<string, unknown> | null;
	routing: RouteResult;
	isStream: boolean;
}

async function parseRequest(req: Request): Promise<ParsedRequest> {
	let body: string | null = null;
	let parsedBody: Record<string, unknown> | null = null;
	let routing: RouteResult = {
		model: "unknown",
		originalModel: "unknown",
		upstream: ANTHROPIC_BASE,
		authHeader: {},
	};

	if (req.body) {
		body = await req.text();
		try {
			parsedBody = JSON.parse(body);
			let model = (parsedBody?.model as string) ?? "";

			// Auto-tier: downgrade model for small/simple requests to save cost
			if (AUTO_TIER && model && parsedBody && body.length < 500) {
				const lowerModel = model.toLowerCase();
				// Only downgrade if the model is an expensive tier (opus/sonnet)
				if (lowerModel.includes("opus") || lowerModel.includes("sonnet")) {
					// Use the configured haiku id; regex-substituting tier tokens can mangle
					// provider-specific model aliases into names that do not exist.
					const haiku = _optionalEnv("AUTO_TIER_HAIKU_MODEL", configuredModel("auto_tier_haiku"));
					if (haiku) {
						log("info", "Auto-tier: downgraded for small request", { from: model, to: haiku, bodyLen: body.length });
						model = haiku;
						parsedBody.model = haiku;
					} else {
						log("warn", "Auto-tier skipped: missing auto_tier_haiku in model catalog", { from: model, bodyLen: body.length });
					}
				}
			}

			routing = resolveModel(model);

			if (parsedBody && routing.model !== model) {
				parsedBody.model = routing.model;
				body = JSON.stringify(parsedBody);
			}
		} catch {
			// Not JSON or no model field — default to Anthropic
		}
	}

	return { body, parsedBody, routing, isStream: parsedBody?.stream === true };
}

// ── MiniMax error handling ───────────────────────────────────────────
async function handleMiniMaxFetchError(
	req: Request,
	path: string,
	originalModel: string,
	routedModel: string,
	parsedBody: Record<string, unknown> | null,
	err: unknown,
): Promise<Response> {
	recordMiniMaxFailure();
	recordUsage(routedModel, MINIMAX_BASE, 599);
	if (ANTHROPIC_KEY) {
		log("warn", "MiniMax fetch error, falling back to Anthropic", { error: String(err) });
		return await fallbackAfterMiniMaxFailure(
			req, path, originalModel, parsedBody, String(err),
		);
	}
	return new Response(`Upstream error: ${err}`, { status: 502 });
}

async function fallbackAfterMiniMaxFailure(
	req: Request,
	path: string,
	originalModel: string,
	parsedBody: Record<string, unknown> | null,
	primaryError: string,
): Promise<Response> {
	try {
		return await fallbackToAnthropic(req, path, originalModel, parsedBody);
	} catch (fallbackErr) {
		return new Response(
			`Both upstreams failed. MiniMax: ${primaryError}. Anthropic: ${fallbackErr}`,
			{ status: 502 },
		);
	}
}

// ── Stream validation ───────────────────────────────────────────────
function isStreamFormatInvalid(isStream: boolean, isMiniMax: boolean, res: Response): boolean {
	if (!isMiniMax || !isStream || !ANTHROPIC_KEY) return false;
	const contentType = res.headers.get("content-type") ?? "";
	if (!contentType.includes("text/event-stream")) {
		log("warn", "MiniMax stream format mismatch, falling back to Anthropic", {
			expected: "text/event-stream",
			got: contentType,
		});
		return true;
	}
	return false;
}

// ── Upstream fetch with fallback ────────────────────────────────────
async function proxyUpstream(req: Request, path: string, parsed: ParsedRequest): Promise<Response> {
	const { body, parsedBody, routing, isStream } = parsed;
	const isMiniMax = routing.upstream === MINIMAX_BASE;
	const target = `${routing.upstream}${path}`;

	log("info", "proxy", {
		from: routing.originalModel,
		to: routing.model !== routing.originalModel ? routing.model : undefined,
		upstream: isMiniMax ? "MiniMax" : "Anthropic",
		method: req.method,
		path,
		stream: isStream || undefined,
	});

	const headers = buildHeaders(req, routing.authHeader, routing.upstream);

	const timeout = upstreamFetchTimeout(isStream);
	let upstreamRes: Response;
	try {
		upstreamRes = await fetch(target, {
			method: req.method,
			headers,
			body,
			signal: timeout.signal,
		});
	} catch (err) {
		if (isMiniMax) {
			return await handleMiniMaxFetchError(
				req, path, routing.originalModel, routing.model, parsedBody, err,
			);
		}
		return new Response(`Upstream error: ${err}`, { status: 502 });
	} finally {
		timeout.clearAfterHeaders();
	}

	if (isMiniMax && upstreamRes.status >= 500 && ANTHROPIC_KEY) {
		recordMiniMaxFailure();
		recordUsage(routing.model, routing.upstream, upstreamRes.status);
		await upstreamRes.body?.cancel();
		log("warn", "MiniMax error, falling back to Anthropic", { status: upstreamRes.status });
		return await fallbackAfterMiniMaxFailure(
			req, path, routing.originalModel, parsedBody, `HTTP ${upstreamRes.status}`,
		);
	}

	// Stream format validation: if we requested streaming but MiniMax didn't return SSE
	if (isStreamFormatInvalid(isStream, isMiniMax, upstreamRes)) {
		recordMiniMaxFailure();
		recordUsage(routing.model, routing.upstream, 502);
		await upstreamRes.body?.cancel();
		return await fallbackAfterMiniMaxFailure(
			req, path, routing.originalModel, parsedBody, "invalid stream format",
		);
	}

	if (isMiniMax) recordMiniMaxSuccess();

	try {
		return await meteredUpstreamResponse(
			upstreamRes,
			routing.model,
			routing.upstream,
			isStream,
		);
	} catch (err) {
		if (isMiniMax) {
			return await handleMiniMaxFetchError(
				req, path, routing.originalModel, routing.model, parsedBody, err,
			);
		}
		return new Response(`Upstream error: ${err}`, { status: 502 });
	}
}

// ── Deep health check ───────────────────────────────────────────────
let deepHealthCache: { ts: number; result: Record<string, unknown> } | null = null;
const DEEP_HEALTH_TTL_MS = 60_000;

async function deepHealthCheck(): Promise<Record<string, unknown>> {
	if (deepHealthCache && Date.now() - deepHealthCache.ts < DEEP_HEALTH_TTL_MS) {
		return deepHealthCache.result;
	}

	const checks: Record<string, unknown> = {};

	// Test Anthropic connectivity
	if (ANTHROPIC_KEY) {
		try {
			const res = await fetch(`${ANTHROPIC_BASE}/v1/models`, {
				headers: { "x-api-key": ANTHROPIC_KEY },
				signal: AbortSignal.timeout(5000),
			});
			checks.anthropic = { reachable: true, status: res.status, valid: res.status < 400 };
		} catch (err) {
			checks.anthropic = { reachable: false, error: String(err) };
		}
	} else {
		checks.anthropic = { reachable: false, error: "no API key" };
	}

	// Test MiniMax connectivity
	if (MINIMAX_TOKEN) {
		try {
			const res = await fetch(`${MINIMAX_BASE}/v1/models`, {
				headers: { Authorization: `Bearer ${MINIMAX_TOKEN}` },
				signal: AbortSignal.timeout(5000),
			});
			checks.minimax = { reachable: true, status: res.status, valid: res.status < 400 };
		} catch (err) {
			checks.minimax = { reachable: false, error: String(err) };
		}
	} else {
		checks.minimax = { reachable: false, error: "no token" };
	}

	deepHealthCache = { ts: Date.now(), result: checks };
	return checks;
}

// ── Exports for testing ─────────────────────────────────────────────
export {
	isMiniMaxModel,
	isOllamaModel,
	resolveModel,
	buildHeaders,
	parseRequest,
	isCircuitOpen,
	recordMiniMaxFailure,
	recordMiniMaxSuccess,
	recordUsage,
	extractUsageFromBody,
	mergeSSEUsage,
	usageStats,
	ANTHROPIC_BASE,
	MINIMAX_BASE,
	OLLAMA_BASE,
	MINIMAX_MODELS,
	OLLAMA_MODELS,
	MODEL_MAP,
};

// Reset circuit breaker state (for testing)
export function resetCircuitBreaker() {
	minimaxFailCount = 0;
	minimaxCircuitOpenUntil = 0;
}

// ── Server ──────────────────────────────────────────────────────────
const server = Bun.serve({
	port: PORT,
	hostname: "127.0.0.1", // loopback-only: the only auth on /ingest, and the proxy is local-only by design
	idleTimeout: 255, // Bun defaults to 10s, which kills long streaming LLM responses mid-flight ("Connection closed mid-response"). 255s = Bun's max.
	async fetch(req) {
		const url = new URL(req.url);
		const path = url.pathname + url.search;

		// ── /ingest — fold an out-of-band usage record (codex/GPT delegate runs) ──
		if (url.pathname === "/ingest") {
			if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
			try {
				const rec = (await req.json()) as Record<string, unknown>;
				return Response.json(ingestUsage(rec));
			} catch (err) {
				return new Response(`bad ingest payload: ${err}`, { status: 400 });
			}
		}

		// ── /stats endpoint — token usage and cost tracking ──
		if (url.pathname === "/stats") {
			const reset = url.searchParams.get("reset") === "true";
			const response = {
				startedAt: usageStats.startedAt,
				totalRequests: usageStats.totalRequests,
				totalInputTokens: usageStats.totalInputTokens,
				totalOutputTokens: usageStats.totalOutputTokens,
				totalTokens: usageStats.totalInputTokens + usageStats.totalOutputTokens,
				cacheCreationTokens: usageStats.totalCacheCreationTokens,
				cacheReadTokens: usageStats.totalCacheReadTokens,
				totalCostUsd: usageStats.totalCostUsd,
				byModel: Object.fromEntries(usageStats.byModel),
				byUpstream: Object.fromEntries(usageStats.byUpstream),
				recentEntries: usageStats.recentEntries.slice(-10),
				logDir: USAGE_LOG_DIR,
			};
			if (reset) {
				usageStats.totalRequests = 0;
				usageStats.totalInputTokens = 0;
				usageStats.totalOutputTokens = 0;
				usageStats.totalCacheCreationTokens = 0;
				usageStats.totalCacheReadTokens = 0;
				usageStats.totalCostUsd = 0;
				usageStats.byModel.clear();
				usageStats.byUpstream.clear();
				usageStats.recentEntries.length = 0;
				usageStats.startedAt = new Date().toISOString();
			}
			return Response.json(response);
		}

		if (url.pathname === "/health") {
			const circuitOpen = isCircuitOpen();
			const healthy = (!!ANTHROPIC_KEY || !!MINIMAX_TOKEN) && !circuitOpen;
			let healthStatus: string;
			if (circuitOpen) {
				healthStatus = "circuit-open";
			} else if (healthy) {
				healthStatus = "ok";
			} else {
				healthStatus = "degraded";
			}
			const cacheHitRate = usageStats.totalInputTokens > 0
				? ((usageStats.totalCacheReadTokens / (usageStats.totalInputTokens + usageStats.totalCacheReadTokens)) * 100).toFixed(1)
				: "0.0";
			const response: Record<string, unknown> = {
				status: healthStatus,
				anthropicKeySet: !!ANTHROPIC_KEY,
				minimaxTokenSet: !!MINIMAX_TOKEN,
				circuitBreaker: { open: circuitOpen, failCount: minimaxFailCount },
				port: PORT,
				routes: { minimaxModels: MINIMAX_MODELS, modelMap: Object.fromEntries(MODEL_MAP) },
				usage: {
					requests: usageStats.totalRequests,
					inputTokens: usageStats.totalInputTokens,
					outputTokens: usageStats.totalOutputTokens,
					cacheReadTokens: usageStats.totalCacheReadTokens,
					cacheHitRate: `${cacheHitRate}%`,
				},
			};

			if (url.searchParams.get("deep") === "true") {
				response.upstreams = await deepHealthCheck();
			}

			return Response.json(response);
		}

		const parsed = await parseRequest(req);
		return proxyUpstream(req, path, parsed);
	},
});

async function fallbackToAnthropic(
	req: Request,
	path: string,
	originalModel: string,
	parsedBody: Record<string, unknown> | null,
): Promise<Response> {
	// Restore original model name and route to Anthropic
	let fallbackBody: string | null = null;
	if (parsedBody) {
		parsedBody.model = originalModel;
		fallbackBody = JSON.stringify(parsedBody);
	}

	const fallbackHeaders = buildHeaders(req, { "x-api-key": ANTHROPIC_KEY }, ANTHROPIC_BASE);
	const fallbackTarget = `${ANTHROPIC_BASE}${path}`;

	const timeout = upstreamFetchTimeout(parsedBody?.stream === true);
	let res: Response;
	try {
		res = await fetch(fallbackTarget, {
			method: req.method,
			headers: fallbackHeaders,
			body: fallbackBody,
			signal: timeout.signal,
		});
	} catch (err) {
		recordUsage(originalModel, ANTHROPIC_BASE, 599);
		throw err;
	} finally {
		timeout.clearAfterHeaders();
	}

	log("info", "Anthropic fallback", { status: res.status });

	try {
		return await meteredUpstreamResponse(
			res,
			originalModel,
			ANTHROPIC_BASE,
			parsedBody?.stream === true,
		);
	} catch (err) {
		recordUsage(originalModel, ANTHROPIC_BASE, 599);
		throw err;
	}
}

// ── Graceful shutdown ───────────────────────────────────────────────
function shutdown(signal: string) {
	log("info", "Shutting down", { signal });
	server.stop();
	process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ── Startup ─────────────────────────────────────────────────────────
log("info", "Legion Router started", {
	port: PORT,
	anthropic: ANTHROPIC_BASE,
	minimax: MINIMAX_BASE,
	ollama: OLLAMA_BASE,
	anthropicKeySet: !!ANTHROPIC_KEY,
	minimaxTokenSet: !!MINIMAX_TOKEN,
	ollamaModels: OLLAMA_MODELS.length > 0 ? OLLAMA_MODELS : undefined,
	minimaxModels: MINIMAX_MODELS,
	modelMap: Object.fromEntries(MODEL_MAP),
	fallback: !!ANTHROPIC_KEY,
});
