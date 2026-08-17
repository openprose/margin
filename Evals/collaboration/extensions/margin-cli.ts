/**
 * Trusted Prime Agent boundary for live Margin collaboration evaluations.
 *
 * The model receives exactly one tool.  This extension deliberately does not
 * expose a shell or filesystem API: it executes the eval's existing headless
 * proxy at one fixed path, in one fixed workspace, with bounded arguments,
 * standard input, runtime, and output.
 */

import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { isAbsolute } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const MAX_ARGUMENTS = 96;
const MAX_ARGUMENT_BYTES = 16 * 1024;
const MAX_ARGUMENT_VECTOR_BYTES = 64 * 1024;
const MAX_STDIN_BYTES = 128 * 1024;
const MAX_STDIN_NODES = 10_000;
const MAX_STDOUT_BYTES = 160 * 1024;
const MAX_STDERR_BYTES = 16 * 1024;
const COMMAND_TIMEOUT_MS = 95_000;

const MarginCLIParameters = Type.Object(
	{
		argv: Type.Array(
			Type.String({
				description: "One literal Margin CLI argument; omit the executable name.",
				maxLength: MAX_ARGUMENT_BYTES,
			}),
			{
				description: "Literal argv array beginning with a Margin headless command.",
				maxItems: MAX_ARGUMENTS,
				minItems: 1,
			},
		),
		stdin: Type.Optional(
			Type.String({
				description:
					"Bounded UTF-8 standard input. Use only when argv explicitly selects '-' (for example --operations-file -).",
				maxLength: MAX_STDIN_BYTES,
			}),
		),
	},
	{ additionalProperties: false },
);

function utf8Bytes(value: string): number {
	return Buffer.byteLength(value, "utf8");
}

function pathEscape(argument: string): boolean {
	const candidates = [argument];
	if (argument.startsWith("--") && argument.includes("=")) {
		candidates.push(argument.slice(argument.indexOf("=") + 1));
	}
	return candidates.some((candidate) => {
		if (!candidate || candidate === "-") return false;
		if (candidate.includes("\0")) return true;
		if (isAbsolute(candidate) || candidate.startsWith("~")) return true;
		if (/^[A-Za-z]:[\\/]/.test(candidate) || /^file:/i.test(candidate)) return true;
		return candidate.replaceAll("\\", "/").split("/").includes("..");
	});
}

function validateInput(argv: string[], stdin: string | undefined): void {
	if (argv.length < 1 || argv.length > MAX_ARGUMENTS) {
		throw new Error(`margin_cli requires 1-${MAX_ARGUMENTS} argv entries.`);
	}
	let totalBytes = 0;
	for (const argument of argv) {
		const size = utf8Bytes(argument);
		if (size > MAX_ARGUMENT_BYTES) {
			throw new Error("margin_cli rejected an oversized argument.");
		}
		totalBytes += size;
		if (pathEscape(argument)) {
			throw new Error("margin_cli paths must remain relative to the fixed evaluation workspace.");
		}
	}
	if (totalBytes > MAX_ARGUMENT_VECTOR_BYTES) {
		throw new Error("margin_cli rejected an oversized argument vector.");
	}
	if (stdin !== undefined) {
		const inputFlag = argv.findIndex(
			(argument) => argument === "--operations-file" || argument === "--change-set-file",
		);
		if (inputFlag < 0 || argv[inputFlag + 1] !== "-") {
			throw new Error("margin_cli stdin is limited to an explicit staged JSON '-' input.");
		}
		if (utf8Bytes(stdin) > MAX_STDIN_BYTES) {
			throw new Error("margin_cli rejected oversized standard input.");
		}
		let payload: unknown;
		try {
			payload = JSON.parse(stdin);
		} catch {
			throw new Error("margin_cli staged standard input must be valid JSON.");
		}
		const pending: unknown[] = [payload];
		let visited = 0;
		while (pending.length > 0) {
			visited += 1;
			if (visited > MAX_STDIN_NODES) {
				throw new Error("margin_cli staged input exceeds its structural bound.");
			}
			const value = pending.pop();
			if (typeof value === "string" && pathEscape(value)) {
				throw new Error("margin_cli staged input contains a path that escapes the fixed workspace.");
			}
			if (Array.isArray(value)) {
				pending.push(...value);
			} else if (value !== null && typeof value === "object") {
				pending.push(...Object.values(value as Record<string, unknown>));
			}
		}
	}
}

interface Capture {
	chunks: Buffer[];
	limit: number;
	retained: number;
	total: number;
}

function capture(captureState: Capture, chunk: Buffer): void {
	captureState.total += chunk.length;
	const remaining = captureState.limit - captureState.retained;
	if (remaining <= 0) return;
	const retained = chunk.subarray(0, remaining);
	captureState.chunks.push(retained);
	captureState.retained += retained.length;
}

function decoded(captureState: Capture): string {
	return Buffer.concat(captureState.chunks).toString("utf8");
}

function childEnvironment(): NodeJS.ProcessEnv {
	const allowed = new Set([
		"LANG",
		"NO_COLOR",
		"PATH",
		"TERM",
		"TMPDIR",
		"MARGIN_ACTOR_ID",
		"MARGIN_ACTOR_NAME",
		"MARGIN_ACTOR_TYPE",
		"MARGIN_COLLAB_COMMAND_LOG",
		"MARGIN_COLLAB_REAL_BIN",
		"MARGIN_COLLAB_ROLE_HASH",
		"MARGIN_COLLAB_WORKSPACE",
	]);
	const environment: NodeJS.ProcessEnv = {};
	for (const [key, value] of Object.entries(process.env)) {
		if ((allowed.has(key) || key.startsWith("LC_")) && value !== undefined) {
			environment[key] = value;
		}
	}
	environment.MARGIN_COLLAB_CONFINED = "1";
	return environment;
}

export default function marginCollaborationExtension(pi: ExtensionAPI) {
	const configuredProxy = process.env.MARGIN_COLLAB_PROXY_BIN;
	const configuredWorkspace = process.env.MARGIN_COLLAB_WORKSPACE;
	if (!configuredProxy || !configuredWorkspace) {
		throw new Error("The trusted Margin evaluation tool is not configured.");
	}
	const proxyPath = realpathSync(configuredProxy);
	const workspace = realpathSync(configuredWorkspace);

	pi.registerTool({
		name: "margin_cli",
		label: "Margin CLI",
		description:
			"Run one headless Margin collaboration command inside the fixed evaluation workspace. Pass literal argv without the `margin` executable. No shell expansion is performed. Absolute paths and parent traversal are rejected. Output is bounded.",
		promptSnippet: "Execute bounded Margin CLI collaboration commands in the fixed evaluation workspace",
		promptGuidelines: [
			"Use margin_cli for every document read, context lookup, collaboration mutation, validation, and merge in this evaluation.",
			"Pass paths relative to the fixed workspace and request machine-readable output when the command offers it.",
			"Prefer margin_cli argv [\"help\", COMMAND, SUBCOMMAND] or a task-specific capability slice for discovery; request the full capabilities catalog only when focused help is insufficient.",
			"For a staged intent plan, call margin_cli with --operations-file - and provide the versioned plan JSON in stdin.",
		],
		parameters: MarginCLIParameters,

		async execute(_toolCallId, params, signal) {
			const argv = [...params.argv];
			const stdin = params.stdin;
			validateInput(argv, stdin);
			if (signal?.aborted) {
				throw new Error("margin_cli was cancelled before execution.");
			}

			const stdout: Capture = { chunks: [], limit: MAX_STDOUT_BYTES, retained: 0, total: 0 };
			const stderr: Capture = { chunks: [], limit: MAX_STDERR_BYTES, retained: 0, total: 0 };
			const result = await new Promise<{ exitCode: number; timedOut: boolean }>((resolveResult, reject) => {
				const child = spawn(proxyPath, argv, {
					cwd: workspace,
					detached: true,
					env: {
						...childEnvironment(),
						MARGIN_COLLAB_STDIN_PRESENT: stdin === undefined ? "0" : "1",
					},
					shell: false,
					stdio: ["pipe", "pipe", "pipe"],
				});
				let timedOut = false;
				let settled = false;

				const terminate = () => {
					if (child.pid !== undefined) {
						try {
							process.kill(-child.pid, "SIGTERM");
						} catch {
							child.kill("SIGTERM");
						}
					}
				};
				const abort = () => terminate();
				const timer = setTimeout(() => {
					timedOut = true;
					terminate();
				}, COMMAND_TIMEOUT_MS);

				signal?.addEventListener("abort", abort, { once: true });
				child.stdout.on("data", (chunk: Buffer) => capture(stdout, chunk));
				child.stderr.on("data", (chunk: Buffer) => capture(stderr, chunk));
				child.on("error", (error) => {
					if (settled) return;
					settled = true;
					clearTimeout(timer);
					signal?.removeEventListener("abort", abort);
					reject(error);
				});
				child.on("close", (code) => {
					if (settled) return;
					settled = true;
					clearTimeout(timer);
					signal?.removeEventListener("abort", abort);
					resolveResult({ exitCode: timedOut ? 124 : (code ?? 74), timedOut });
				});
				child.stdin.end(stdin ?? "", "utf8");
			});

			const response = {
				exitCode: result.exitCode,
				stderr: decoded(stderr),
				stderrBytes: stderr.total,
				stderrTruncated: stderr.total > stderr.retained,
				stdout: decoded(stdout),
				stdoutBytes: stdout.total,
				stdoutTruncated: stdout.total > stdout.retained,
				timedOut: result.timedOut,
			};
			return {
				content: [{ type: "text" as const, text: JSON.stringify(response) }],
				details: {
					exitCode: response.exitCode,
					stderrBytes: response.stderrBytes,
					stderrTruncated: response.stderrTruncated,
					stdoutBytes: response.stdoutBytes,
					stdoutTruncated: response.stdoutTruncated,
					timedOut: response.timedOut,
				},
			};
		},
	});
}
