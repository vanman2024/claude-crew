#!/bin/bash
# Orchestrator hook — called by worktree Claude sessions on Notification/Stop/PostToolUse events
# Reads JSON from stdin, writes status + activity log to shared orchestrator directory
# Uses node (always available) instead of jq
#
# Project-agnostic: the status dir is derived at runtime from the hook payload's cwd.
# A worktree lives at <worktreesBase>/<name>, so the shared status dir is
# <worktreesBase>/.orchestrator = dirname(cwd) + '/.orchestrator'.

# Read the hook event JSON from stdin
INPUT=$(cat)

# Use node to parse JSON, write status file, and append to activity log
node -e "
const input = JSON.parse(process.argv[1]);
const path = require('path');
const fs = require('fs');

const event = input.hook_event_name || 'unknown';
const sessionId = input.session_id || 'unknown';
const cwd = input.cwd || 'unknown';
const toolName = input.tool_name || '';
const toolInput = input.tool_input || {};
const worktreeName = path.basename(cwd);
const timestamp = new Date().toISOString();

// Derive the shared status dir from cwd (parent of the worktree).
const STATUS_DIR = path.dirname(cwd) + '/.orchestrator';
fs.mkdirSync(STATUS_DIR, {recursive: true});

let status = 'unknown';
if (event === 'Notification') status = 'idle';
else if (event === 'Stop') status = 'stopped';
else if (event === 'PostToolUse') status = 'working';

// On Stop, write a completion marker so the orchestrator can detect finished agents
if (event === 'Stop') {
  const doneFile = path.join(STATUS_DIR, worktreeName + '.done');
  const doneObj = {
    worktree: worktreeName,
    timestamp,
    session_id: sessionId,
    cwd
  };
  fs.writeFileSync(doneFile, JSON.stringify(doneObj, null, 2) + '\\n');
}

// Extract useful context from tool input
let detail = '';
if (toolName === 'Write' || toolName === 'Edit' || toolName === 'Read') {
  detail = toolInput.file_path || '';
} else if (toolName === 'Agent') {
  detail = (toolInput.subagent_type || 'general') + ': ' + (toolInput.description || '');
} else if (toolName === 'Bash') {
  detail = (toolInput.command || '').substring(0, 120);
} else if (toolName === 'Glob') {
  detail = toolInput.pattern || '';
} else if (toolName === 'Grep') {
  detail = toolInput.pattern || '';
} else if (toolName === 'Skill') {
  detail = toolInput.skill || '';
}

const statusObj = {
  worktree: worktreeName,
  status,
  event,
  session_id: sessionId,
  timestamp,
  cwd
};
if (toolName) statusObj.last_tool = toolName;
if (detail) statusObj.detail = detail;

// Write current status
const statusFile = path.join(STATUS_DIR, worktreeName + '.status');
fs.writeFileSync(statusFile, JSON.stringify(statusObj, null, 2) + '\n');

// Append to activity log (last 200 lines kept)
if (toolName) {
  const logFile = path.join(STATUS_DIR, worktreeName + '.log');
  const ts = timestamp.substring(11, 19);
  const line = ts + ' ' + toolName + (detail ? ' | ' + detail : '') + '\n';
  fs.appendFileSync(logFile, line);

  // Trim to last 200 lines periodically
  try {
    const content = fs.readFileSync(logFile, 'utf8');
    const lines = content.split('\n').filter(Boolean);
    if (lines.length > 250) {
      fs.writeFileSync(logFile, lines.slice(-200).join('\n') + '\n');
    }
  } catch {}
}
" "$INPUT" 2>/dev/null
