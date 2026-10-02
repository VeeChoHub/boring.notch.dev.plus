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

function run() {
    const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile
    const e = JSON.parse($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js)
    const event = e.hook_event_name
    // Senza hook_event_name l'input è della statusline
    if (!event) {
        if (e.rate_limits) post('limits', $(), { json: JSON.stringify(e.rate_limits) })
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
    let state = 'idle' // SessionStart, StopFailure, Notification(idle_prompt), Esc durante un tool
    if (['AskUserQuestion', 'ExitPlanMode'].includes(e.tool_name) && ['PreToolUse', 'PermissionRequest'].includes(event)) state = 'question'
    else if (event === 'PermissionRequest') state = 'permission'
    else if (['UserPromptSubmit', 'PostToolUse'].includes(event) || (event === 'PostToolUseFailure' && !e.is_interrupt)) state = 'working'
    else if (event === 'Stop') state = 'done' // l'app mostra la spunta per 10 s, poi torna idle
    else if (event === 'SessionEnd') state = 'ended'
    post(state, e.session_id, { cwd: e.cwd || '' })
}
