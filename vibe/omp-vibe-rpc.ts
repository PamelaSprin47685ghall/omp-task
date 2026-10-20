#!/usr/bin/env bun
/**
 * omp-vibe-rpc — run `omp` (any normal CLI args, typically `--mode rpc --no-ui ...`)
 * with vibe mode active on the top-level session.
 *
 * omp 18.12.4 implements /vibe only as a TUI slash command (slash-commands/builtin-modes.ts:359,
 * handleTui only; modes/interactive-mode.ts handleVibeModeCommand/#enterVibeMode). RPC mode has no
 * vibe command, setting, or rehydration (modes/rpc/* only has rpc-goal.ts). The vibe *runtime* is
 * not TUI-specific though: every top-level SDK session is built with createVibeTools (sdk.ts:4792)
 * and AgentSession exposes activateVibeTools/setVibeModeState publicly.
 *
 * Hook: main.ts exports runRootCommand(parsed, rawArgs, deps) whose deps.createAgentSession
 * (main.ts:1755-1763, used at :2323) is the dependency-injection seam for the root session.
 * We call the real createAgentSession, then apply exactly the steps of
 * InteractiveMode#enterVibeMode (interactive-mode.ts:6287-6345), and let omp's own main.ts
 * continue into runRpcMode with every CLI flag intact. On --continue of a session whose
 * persisted mode is already "vibe" we skip the mode_change append and rehydrate parked
 * workers, as InteractiveMode#reconcileModeFromSession does (interactive-mode.ts:5073,5107).
 *
 * Env: OMP_VIBE=0 disables the hook (plain omp from source).
 */
import { parseArgs, reportCliUsageError } from "@oh-my-pi/pi-coding-agent/cli/args";
import { formatModelString } from "@oh-my-pi/pi-coding-agent/config/model-resolver";
import { runRootCommand } from "@oh-my-pi/pi-coding-agent/main";
import { createAgentSession } from "@oh-my-pi/pi-coding-agent/sdk";
import { VibeSessionRegistry } from "@oh-my-pi/pi-coding-agent/vibe/runtime";

type Session = Awaited<ReturnType<typeof createAgentSession>>["session"];

async function enterVibeMode(session: Session): Promise<void> {
	const sessionManager = session.sessionManager;
	// Same shape as InteractiveMode#vibeParentSession (interactive-mode.ts:4789).
	const parent = {
		getAgentId: () => session.getAgentId() ?? null,
		getSessionId: () => sessionManager.getSessionId(),
		getSessionFile: () => sessionManager.getSessionFile() ?? null,
		sessionManager,
		asyncJobManager: session.asyncJobManager,
		settings: session.settings,
		getActiveModelString: () => (session.model ? formatModelString(session.model) : undefined),
	};
	const registry = VibeSessionRegistry.global();
	const resumed = sessionManager.buildSessionContext().mode === "vibe";
	registry.activateScope(registry.ownerScope(parent));
	const previousTools = session.getEnabledToolNames();
	const baseTools = ["read"];
	if (session.hasBuiltInTool("todo")) baseTools.push("todo");
	await session.activateVibeTools(baseTools);
	session.setVibeModeState({ enabled: true });
	if (resumed) {
		await registry.rehydrate(parent);
	} else {
		sessionManager.appendModeChange("vibe", { previousTools });
	}
	process.stderr.write(
		`[omp-vibe-rpc] vibe mode ${resumed ? "restored" : "enabled"}; tools: ${session.getEnabledToolNames().join(",")}\n`,
	);
}

const argv = process.argv.slice(2);
let parsed;
try {
	parsed = parseArgs(argv);
} catch (error) {
	if (reportCliUsageError(error)) process.exit(2);
	throw error;
}
let rootSessionDone = false;
await runRootCommand(parsed, argv, {
	createAgentSession: async options => {
		const result = await createAgentSession(options);
		if (!rootSessionDone && process.env.OMP_VIBE !== "0") {
			rootSessionDone = true; // only the root session; subagents never go through this seam
			await enterVibeMode(result.session);
		}
		return result;
	},
});
