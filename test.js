const WebSocket = require('ws');

const WS_URL = 'ws://localhost:7778/ws';

function send(ws, msg) {
  const json = JSON.stringify(msg);
  ws.send(json);
  const preview = json.length > 120 ? json.slice(0, 120) + '...' : json;
  console.log(`  → ${preview}`);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function simulateTasks(ws) {
  console.log('\n--- Spawning 3 parallel tasks ---\n');

  // Task 1: Gmail search (will take longest)
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'status',
    data: {
      task: 'Search Gmail for flight booking confirmation and extract travel details',
      description: 'Search flight emails',
      status: 'running',
      tool_calls_count: 0,
    },
  });

  // Task 2: Notion notes
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-notion-002',
    event_type: 'status',
    data: {
      task: 'Create a new page in Notion with meeting notes from today\'s standup',
      description: 'Create meeting notes',
      status: 'running',
      tool_calls_count: 0,
    },
  });

  // Task 3: Linear update
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-linear-003',
    event_type: 'status',
    data: {
      task: 'Update Linear ticket GH-142 status to In Review and add a comment with PR link',
      description: 'Update Linear ticket',
      status: 'running',
      tool_calls_count: 0,
    },
  });

  await sleep(1500);

  // --- Task 1: tool calls ---
  console.log('\n--- Task 1: gmail_search ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'progress',
    data: { type: 'tool_start', tool_name: 'gmail_search', tool_id: 't1' },
  });

  await sleep(800);

  // --- Task 3: quick tool call + finish ---
  console.log('\n--- Task 3: linear_update_issue ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-linear-003',
    event_type: 'progress',
    data: { type: 'tool_start', tool_name: 'linear_update_issue', tool_id: 't3a' },
  });

  await sleep(600);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-linear-003',
    event_type: 'progress',
    data: { type: 'tool_result', tool_name: 'linear_update_issue', tool_id: 't3a', success: true },
  });

  await sleep(400);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-linear-003',
    event_type: 'progress',
    data: { type: 'tool_start', tool_name: 'linear_add_comment', tool_id: 't3b' },
  });

  await sleep(500);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-linear-003',
    event_type: 'progress',
    data: { type: 'tool_result', tool_name: 'linear_add_comment', tool_id: 't3b', success: true },
  });

  await sleep(300);

  console.log('\n--- Task 3: completed ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-linear-003',
    event_type: 'done',
    data: {
      status: 'completed',
      result: 'Updated GH-142 to "In Review". Added comment: "PR #287 ready for review — all tests passing."',
    },
  });

  await sleep(1000);

  // --- Task 1: gmail results ---
  console.log('\n--- Task 1: gmail_search result ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'progress',
    data: { type: 'tool_result', tool_name: 'gmail_search', tool_id: 't1', success: true },
  });

  await sleep(300);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'progress',
    data: {
      type: 'token',
      text: 'Found 2 flight confirmation emails. Extracting details from the most recent booking...',
    },
  });

  await sleep(500);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'progress',
    data: { type: 'tool_start', tool_name: 'gmail_read_email', tool_id: 't1b' },
  });

  // --- Task 2: Notion tool calls ---
  console.log('\n--- Task 2: notion_create_page ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-notion-002',
    event_type: 'progress',
    data: { type: 'tool_start', tool_name: 'notion_create_page', tool_id: 't2a' },
  });

  await sleep(1200);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-notion-002',
    event_type: 'progress',
    data: { type: 'tool_result', tool_name: 'notion_create_page', tool_id: 't2a', success: true },
  });

  await sleep(400);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-notion-002',
    event_type: 'progress',
    data: { type: 'tool_start', tool_name: 'notion_append_block', tool_id: 't2b' },
  });

  await sleep(800);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-notion-002',
    event_type: 'progress',
    data: { type: 'tool_result', tool_name: 'notion_append_block', tool_id: 't2b', success: true },
  });

  await sleep(300);

  console.log('\n--- Task 2: completed ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-notion-002',
    event_type: 'done',
    data: {
      status: 'completed',
      result: 'Created page "Standup Notes — Mar 20" in Engineering workspace. Added agenda items, action items, and attendee list.',
    },
  });

  await sleep(1500);

  // --- Task 1: final steps ---
  console.log('\n--- Task 1: reading email ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'progress',
    data: { type: 'tool_result', tool_name: 'gmail_read_email', tool_id: 't1b', success: true },
  });

  await sleep(500);

  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'progress',
    data: {
      type: 'thinking_complete',
      text: 'Flight: UA 247, SFO → JFK, Mar 28 at 8:15 AM. Confirmation #: XKCD42. Seat 14A (window). Terminal 3.',
    },
  });

  await sleep(800);

  console.log('\n--- Task 1: completed ---');
  send(ws, {
    type: 'subagent_event',
    session_id: 'task-gmail-001',
    event_type: 'done',
    data: {
      status: 'completed',
      result: 'Flight: United UA 247\nRoute: SFO → JFK\nDate: Mar 28, 2026 at 8:15 AM\nConfirmation: XKCD42\nSeat: 14A (window)\nTerminal: 3, Gate B22',
    },
  });

  console.log('\n--- All tasks completed! ---\n');
}

// Connect and run
console.log(`Connecting to ${WS_URL}...`);
const ws = new WebSocket(WS_URL);

ws.on('open', async () => {
  console.log('Connected!\n');
  await simulateTasks(ws);
  await sleep(2000);
  ws.close();
  console.log('Done. Disconnected.');
  process.exit(0);
});

ws.on('error', (err) => {
  console.error(`Connection failed: ${err.message}`);
  console.error('Make sure Danotch is running: cd danotch && swift run Danotch');
  process.exit(1);
});
