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
		if (url.pathname !== "/v1/messages" || req.method !== "POST") {
			return new Response("not found", { status: 404 });
		}
		if (req.headers.get("x-test-hang-headers") === "1") {
			await sleep(10_000);
			return Response.json({ ok: false }, { status: 504 });
		}

		const stream = new ReadableStream<Uint8Array>({
			async start(controller) {
				controller.enqueue(encoder.encode('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":3}}}\n\n'));
				await sleep(50);
				controller.enqueue(encoder.encode('event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\n'));
				await sleep(50);
				controller.enqueue(encoder.encode('event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n'));
				await sleep(25);
				controller.enqueue(encoder.encode('event: message_stop\ndata: {"type":"message_stop"}\n\n'));
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
