const port = Number.parseInt(process.env.ROUTER_STREAM_UPSTREAM_PORT || "8190", 10);
const encoder = new TextEncoder();

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

Bun.serve({
	port,
	hostname: "127.0.0.1",
	async fetch(req) {
		const url = new URL(req.url);
		if (url.pathname === "/health") {
			return Response.json({ ok: true });
		}
		if (!url.pathname.endsWith("/v1/messages") || req.method !== "POST") {
			return new Response("not found", { status: 404 });
		}
		if (req.headers.get("x-test-hang-headers") === "1") {
			await sleep(10_000);
			return Response.json({ ok: false }, { status: 504 });
		}
		const body = await req.clone().json().catch(() => ({})) as Record<string, unknown>;
		const isFallbackFixture = body.model === "minimax-fallback";
		if (isFallbackFixture && req.headers.get("authorization")?.startsWith("Bearer ")) {
			return Response.json({ error: "minimax unavailable" }, { status: 503 });
		}
		if (isFallbackFixture && body.stream !== true) {
			return Response.json({
				content: [{ type: "text", text: "fallback ok" }],
				usage: { input_tokens: 11, output_tokens: 5 },
			});
		}

		if (req.headers.get("x-test-slow-stream") === "1") {
			let step = 0;
			const chunks = [
				'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":3}}}\n\n',
				'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"later"}}\n\n',
				'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n',
			];
			const stream = new ReadableStream<Uint8Array>({
				async pull(controller) {
					if (step > 0) await sleep(1_000);
					if (step >= chunks.length) {
						controller.close();
						return;
					}
					controller.enqueue(encoder.encode(chunks[step++]));
				},
			});
			return new Response(stream, { status: 200, headers: { "content-type": "text/event-stream" } });
		}
		if (req.headers.get("x-test-error-stream") === "1") {
			const stream = new ReadableStream<Uint8Array>({
				async start(controller) {
					controller.enqueue(encoder.encode('event: message_start\ndata: {"type":"message_start"}\n\n'));
					// End after headers and the first event, but without message_stop.
					// Across runtimes an upstream socket reset may surface as either a
					// rejected read or clean EOF; the proxy must reject both truncations.
					await sleep(50);
					controller.close();
				},
			});
			return new Response(stream, { status: 200, headers: { "content-type": "text/event-stream" } });
		}

		const stream = new ReadableStream<Uint8Array>({
			async start(controller) {
				controller.enqueue(encoder.encode('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":3}}}\n\n'));
				await sleep(50);
				controller.enqueue(encoder.encode('event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\n'));
				await sleep(50);
				controller.enqueue(encoder.encode('event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n'));
				await sleep(25);
				// The post-colon space is optional in valid SSE.
				controller.enqueue(encoder.encode('event: message_stop\ndata:{"type":"message_stop"}\n\n'));
				controller.close();
			},
		});

		return new Response(stream, {
			status: 200,
			headers: {
				"content-type": "text/event-stream",
				"cache-control": "no-cache",
			},
		});
	},
});
