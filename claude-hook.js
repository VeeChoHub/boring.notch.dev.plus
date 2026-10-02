#!/usr/bin/osascript -l JavaScript
// Hook di Claude Code -> sessioni nel notch (BoringViewCoordinator.claudeSessions).
// Registrato in ~/.claude/settings.json. Invia la distributed notification
// "boringnotch.claude.<stato>" con object = session_id e userInfo = { cwd }.
// Non deve stampare nulla: lo stdout di UserPromptSubmit/SessionStart finirebbe nel contesto di Claude.
ObjC.import('Foundation')

function post(name, object, info) {
    $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
        'boringnotch.claude.' + name, object, $(info), true)
}

// Ultima riga del transcript (legge solo la coda del file, che può essere grande)
function lastTranscriptEntry(path) {
    const file = $.NSFileHandle.fileHandleForReadingAtPath(path || '')
    if (file.isNil()) return null
    const size = file.seekToEndOfFile
    file.seekToFileOffset(Math.max(0, size - 16384))
    const tail = $.NSString.alloc.initWithDataEncoding(file.readDataToEndOfFile, $.NSUTF8StringEncoding).js || ''
    const line = tail.trim().split('\n').pop()
    try { return JSON.parse(line) } catch (_) { return null }
}

// Token compatti: 85k, 1M, 1.5M (come la statusline)
const k = n => n >= 1e6 ? Math.round(n / 1e5) / 10 + 'M' : Math.round(n / 1000) + 'k'

// $/1M token (input, output) per sottostringa del modello; cache sull'input: 5m 1.25x, 1h 2x, lettura 0.1x
const RATES = [['opus', 5, 25], ['sonnet', 3, 15], ['haiku', 1, 5], ['fable', 10, 50]]

// Token e costo della task (dal prompt corrente in poi): stesse regole di "last task" di task-notifier
// (cost.py), così i numeri coincidono con la statusline. Usage contato una volta per message.id
// (lo streaming lo ripete); token senza cache_read. ponytail: solo transcript principale, i subagent no
function taskUsage(path, promptId) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path || '', $.NSUTF8StringEncoding, null).js || ''
    const start = promptId ? text.indexOf('"promptId":"' + promptId + '"') : -1
    if (start < 0) return ''
    let tokens = 0, cost = 0
    const seen = {}
    for (const line of text.slice(text.lastIndexOf('\n', start) + 1).split('\n')) {
        let m
        try { m = JSON.parse(line).message } catch (_) { continue }
        const u = m && m.usage
        if (!u || seen[m.id]) continue
        seen[m.id] = true
        const [, inR, outR] = RATES.find(([name]) => (m.model || '').includes(name)) || RATES[0]
        const cc = u.cache_creation
        const c5 = cc ? cc.ephemeral_5m_input_tokens || 0 : u.cache_creation_input_tokens || 0
        const c1 = cc ? cc.ephemeral_1h_input_tokens || 0 : 0
        const input = u.input_tokens || 0, output = u.output_tokens || 0
        tokens += input + output + c5 + c1
        cost += (input * inR + c5 * 1.25 * inR + c1 * 2 * inR + (u.cache_read_input_tokens || 0) * 0.1 * inR + output * outR) / 1e6
    }
    return (tokens >= 1000 ? (tokens / (tokens >= 1e6 ? 1e6 : 1000)).toFixed(1) + (tokens >= 1e6 ? 'M' : 'k') : tokens)
        + ' tok | $' + cost.toFixed(2)
}

// `claude-hook.js install <hook> <settings>`: registra lo script come hook e statusline (bottone Install nelle
// impostazioni, via BoringNotchXPCHelper.claudeHook). Idempotente: le vecchie voci di claude-hook.js (anche con
// un altro path) sono sostituite, gli altri hook restano, una statusline estranea viene incapsulata. Backup in .bak
function install(hook, path) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
    const s = text.isNil() ? {} : JSON.parse(text.js)
    if (!text.isNil()) text.writeToFileAtomicallyEncodingError(path + '.bak', true, $.NSUTF8StringEncoding, null)
    const cmd = `"${hook}"` // il path dell'app ha spazi
    const mine = h => (h.command || '').includes('claude-hook.js')
    const events = { SessionStart: '', UserPromptSubmit: '', PreToolUse: 'AskUserQuestion|ExitPlanMode',
        PermissionRequest: '', PostToolUse: '', PostToolUseFailure: '', Stop: '', StopFailure: '',
        SessionEnd: '', Notification: 'idle_prompt', SubagentStart: '', SubagentStop: '' }
    s.hooks = s.hooks || {}
    for (const [event, matcher] of Object.entries(events)) {
        const groups = (s.hooks[event] || []).map(g => ({ ...g, hooks: (g.hooks || []).filter(h => !mine(h)) }))
            .filter(g => g.hooks.length)
        groups.push({ ...(matcher && { matcher }), hooks: [{ type: 'command', command: cmd }] })
        s.hooks[event] = groups
    }
    // La statusline porta limiti di utilizzo, contesto % e rilevamento dell'Esc
    const sl = s.statusLine
    if (!sl) s.statusLine = { type: 'command', command: cmd }
    else if (mine(sl)) sl.command = sl.command.replace(/"[^"]*claude-hook\.js"|[^\s"]*claude-hook\.js/g, () => cmd)
    else sl.command = `input=$(cat)\nprintf %s "$input" | ${cmd} >/dev/null 2>&1 &\nprintf %s "$input" | {\n${sl.command}\n}`
    if (!$(JSON.stringify(s, null, 2)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null))
        throw new Error('Cannot write ' + path)
}

function run(argv) {
    if (argv[0] === 'install') return install(argv[1], argv[2])
    const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile
    const e = JSON.parse($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js)
    const event = e.hook_event_name
    // Senza hook_event_name l'input è della statusline
    if (!event) {
        if (e.rate_limits) post('limits', $(), { json: JSON.stringify(e.rate_limits) })
        // Finestra di contesto della sessione: percentuale accanto al titolo, modello e token usati/totali
        // nella card di fine sessione ("Opus 5.5", "85k/1M"; il nome perde il suffisso "(1M context)")
        const ctx = e.context_window || {}
        if (typeof ctx.used_percentage === 'number') post('context', e.session_id, {
            pct: ctx.used_percentage,
            model: ((e.model || {}).display_name || '').replace(/\s*\(.*\)$/, ''),
            tokens: k((ctx.total_input_tokens || 0) + (ctx.total_output_tokens || 0)) + '/' + k(ctx.context_window_size || 0),
        })
        // Esc mentre Claude risponde non fa scattare nessun hook, ma la statusline riparte e l'ultima riga
        // del transcript è "[Request interrupted by user...]": la sessione torna in attesa. `at` = quando,
        // così l'app ignora un'interruzione più vecchia dell'ultimo prompt
        const last = lastTranscriptEntry(e.transcript_path)
        const content = last && last.type === 'user' && last.message ? last.message.content : null
        const text = Array.isArray(content) ? (content[0] || {}).text : content
        if (typeof text === 'string' && text.startsWith('[Request interrupted by user'))
            post('idle', e.session_id, { cwd: e.cwd || '', at: Date.parse(last.timestamp) / 1000 })
        return
    }
    if (event === 'SessionStart' && e.source === 'compact') return // la compattazione non cambia lo stato
    // Subagent (tool Agent): l'app conta lanciati/finiti per mostrare "SubAgent x/y"
    if (event === 'SubagentStart' || event === 'SubagentStop') {
        post('agent', e.session_id, { cwd: e.cwd || '', agent: e.agent_id, done: event === 'SubagentStop' })
        return
    }
    let state = 'idle' // SessionStart, StopFailure, Notification(idle_prompt), Esc durante un tool
    if (['AskUserQuestion', 'ExitPlanMode'].includes(e.tool_name) && ['PreToolUse', 'PermissionRequest'].includes(event)) state = 'question'
    else if (event === 'PermissionRequest') state = 'permission'
    else if (['UserPromptSubmit', 'PostToolUse'].includes(event) || (event === 'PostToolUseFailure' && !e.is_interrupt)) state = 'working'
    // Stop con subagent/workflow ancora in background ("Waiting for N background agents") non è la fine:
    // Claude riparte quando finiscono. Altrimenti l'app mostra "<nome> Completata" per 5 s, poi torna idle
    else if (event === 'Stop') state = (e.background_tasks || []).some(t => ['subagent', 'workflow'].includes(t.type)) ? 'working' : 'done'
    else if (event === 'SessionEnd') state = 'ended'
    // Fine task: token e costo per la card "Completata"
    post(state, e.session_id, state === 'done' ? { cwd: e.cwd || '', task: taskUsage(e.transcript_path, e.prompt_id) } : { cwd: e.cwd || '' })
}
