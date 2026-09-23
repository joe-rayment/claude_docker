// context-meter.js -- opencode plugin (ContextMeter), claude-orca-7lz.2,
// the headless twin of scripts/context-meter.sh: meters a HEADLESS
// opencode run's (an Orca worker or recon) own most-recent step-finish
// token count, per session. A soft [context-meter] notice is appended to
// every tool result once past CLAUDE_ORCA_CONTEXT_BUDGET; every tool call
// is refused once past CLAUDE_ORCA_CONTEXT_CEILING, aborting the session
// on the 3rd consecutive refusal. Plain ESM, no imports: opencode must be
// able to load this with no node_modules present.

export const ContextMeter = async ({ client }) => {
    function isNonNegInt(v) {
        if (v === undefined || v === null) return false;
        return /^[0-9]+$/.test(String(v));
    }
    function envInt(name, def) {
        const raw = process.env[name];
        return isNonNegInt(raw) ? parseInt(raw, 10) : def;
    }

    const BUDGET = envInt("CLAUDE_ORCA_CONTEXT_BUDGET", 30);
    const CEILING = envInt("CLAUDE_ORCA_CONTEXT_CEILING", 40);
    const WINDOW_ENV = envInt("CLAUDE_ORCA_CONTEXT_WINDOW", 0);

    // budget 0 -> every hook is a no-op.
    if (BUDGET === 0) return {};

    // sessionID -> { pct, providerID, modelID, refusals }
    const sessions = new Map();
    // "providerID/modelID" -> window tokens, looked up once and cached.
    const windowCache = new Map();

    function state(sessionID) {
        let s = sessions.get(sessionID);
        if (!s) {
            s = { pct: 0, providerID: undefined, modelID: undefined, refusals: 0 };
            sessions.set(sessionID, s);
        }
        return s;
    }

    async function windowFor(providerID, modelID) {
        if (WINDOW_ENV > 0) return WINDOW_ENV;
        if (!providerID || !modelID) return 200000;
        const key = providerID + "/" + modelID;
        if (windowCache.has(key)) return windowCache.get(key);
        let win = 200000;
        try {
            const res = await client.config.providers();
            const providers = (res && res.data && res.data.providers) || [];
            const provider = providers.find((p) => p && p.id === providerID);
            const model = provider && provider.models && provider.models[modelID];
            const context = model && model.limit && model.limit.context;
            if (typeof context === "number" && context > 0) win = context;
        } catch (e) {
            win = 200000;
        }
        windowCache.set(key, win);
        return win;
    }

    function softNotice(pct) {
        return (
            `[context-meter] context is at ${pct}% of this agent's window (budget ${BUDGET}%); ` +
            `past this point answer quality drops. Stop exploring: finish the step in hand, ` +
            `then end your final report with this block and stop.\n` +
            `HANDOFF\n` +
            `done: <what is finished, with file:line>\n` +
            `left: <what remains, in order>\n` +
            `facts: <file:line facts the next agent must not re-derive>\n` +
            `next: <the exact prompt a fresh agent should start from>\n` +
            `relay: this agent is finished -- start a fresh one from this block; never message or resume it.`
        );
    }

    function hardRefusal(pct) {
        return (
            `[context-meter] context is at ${pct}% of this agent's window, past the ${CEILING}% ceiling: ` +
            `tool calls are refused. Write your final report now, ending with the HANDOFF block ` +
            `(done, left, facts, next, relay), and stop.`
        );
    }

    return {
        event: async ({ event }) => {
            try {
                if (!event) return;
                if (event.type === "message.updated") {
                    const info = event.properties && event.properties.info;
                    if (info && info.role === "assistant" && info.sessionID) {
                        const s = state(info.sessionID);
                        s.providerID = info.providerID;
                        s.modelID = info.modelID;
                    }
                    return;
                }
                if (event.type === "message.part.updated") {
                    const part = event.properties && event.properties.part;
                    if (!part || part.type !== "step-finish" || !part.sessionID) return;
                    const t = part.tokens || {};
                    let total = t.total;
                    if (!(typeof total === "number" && total > 0)) {
                        total =
                            (t.input || 0) +
                            (t.output || 0) +
                            (t.reasoning || 0) +
                            ((t.cache && t.cache.read) || 0) +
                            ((t.cache && t.cache.write) || 0);
                    }
                    if (!(total > 0)) return; // ignore a zero reading
                    const s = state(part.sessionID);
                    const win = await windowFor(s.providerID, s.modelID);
                    s.pct = Math.floor((total * 100) / win);
                }
            } catch (e) {
                // metering must never break the run
            }
        },

        "tool.execute.after": async (input, output) => {
            try {
                const s = sessions.get(input && input.sessionID);
                if (!s) return;
                if (s.pct >= BUDGET) {
                    output.output = (output.output || "") + "\n\n" + softNotice(s.pct);
                }
            } catch (e) {
                // any error inside -> leave output untouched
            }
        },

        "tool.execute.before": async (input, output) => {
            const s = state(input && input.sessionID);
            if (s.pct >= CEILING) {
                s.refusals += 1;
                if (s.refusals === 3) {
                    try {
                        await client.session.abort({ path: { id: input.sessionID } });
                    } catch (e) {
                        // swallowed -- the abort is best-effort
                    }
                }
                throw new Error(hardRefusal(s.pct));
            }
            s.refusals = 0;
        },
    };
};
