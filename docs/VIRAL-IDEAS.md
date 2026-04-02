# Danotch — Viral Ideas

Ideas that make people screenshot it, share it, and want to install it immediately. The through-line: **your MacBook's notch finally does something useful.**

---

## 1. SCREEN-AWARE AGENT ("it sees what you see")

The notch watches your screen and offers contextual help without you asking.

**How it works:**
- Periodic screenshot capture (every 5-10s) when opted in
- Feed to Claude vision — "what is the user doing right now?"
- Surface contextual actions in the notch based on what's on screen

**Scenarios:**
- You're staring at a stack trace → notch offers "Want me to debug this?"
- You're on a flight booking page → "Want me to check if there's a cheaper option?"
- You're reading a long doc → "Want a summary?"
- You're in a code review → "I see 2 potential issues in this diff"
- You're on Twitter → "This thread has 12 more posts, want a TLDR?"
- You're writing an email → "Your tone sounds aggressive, want me to soften it?"

**Why it goes viral:** The demo video writes itself. "My notch just told me my code had a bug before I even ran it." People will lose their minds. This is the Jarvis moment.

**Implementation:** `screencapture` CLI → base64 → Claude vision API → classify context → suggest action. Low latency path: capture only when user is idle for 3s (no typing/mouse movement).

---

## 2. NATURAL LANGUAGE COMMAND BAR (notch as Spotlight killer)

Global hotkey (e.g. `⌘ + Shift + Space`) drops down the notch with a text input. Type anything in plain English. It just works.

**Examples:**
- "what meetings do I have tomorrow" → checks calendar, shows in notch
- "tell sarah I'll be 10 min late" → finds Sarah's contact, sends Slack DM
- "how much did I spend on AWS this month" → checks billing dashboard
- "play something chill" → controls Spotify
- "block twitter for the next 2 hours" → modifies /etc/hosts
- "what's the weather in tokyo" → instant answer in notch
- "remind me to review the PR at 3pm" → sets reminder

**Why it goes viral:** It's Raycast/Alfred but with an AI brain and it lives in the notch. Zero UI to learn. Just talk to your computer. The form factor is perfect — tiny input, tiny response, gone.

**Implementation:** Global `NSEvent` hotkey → show input bar → send to Claude with tool routing → display result inline. Most queries need 1 tool call. Fast path: under 2 seconds.

---

## 3. LIVE SYSTEM VITALS + AI OPS ("the notch is your server room")

The notch passively shows system health — CPU, memory, network, battery — but with an AI twist: it understands what's happening and why.

**What it shows (collapsed):** Tiny spark lines or segmented bars flanking the notch — CPU left, memory right. Expand for detail.

**The AI layer:**
- "Chrome is using 4.2GB RAM across 47 tabs. Want me to suggest which to close?"
- "Your CPU has been at 90% for 5 minutes — it's the Docker build. ETA: ~3 min"
- "You're on battery with 23% left. At current usage, ~45 min remaining. Want me to kill heavy processes?"
- "Your disk is 92% full. I found 18GB of old Xcode archives. Clean up?"
- "Network is slow — you're uploading a 2GB file to Google Drive in the background"

**Why it goes viral:** iStat Menus meets AI. Devs are obsessed with system stats. Put it in the notch with intelligence and they'll share screenshots all day. The collapsed sparklines flanking the notch would look insane.

**Implementation:** `sysctl`, `ps`, `IOKit` for stats (most already available via macOS APIs). Feed to Claude periodically for analysis. Anomaly detection: alert when something deviates from your baseline.

---

## 4. CLIPBOARD AGENT ("copy anything, it understands")

Every time you copy something, the notch briefly shows what it captured and offers smart actions.

**Copy a URL →** "Summarize this page?" / "Save to reading list?" / "Share to Slack?"
**Copy an error →** "I found 3 StackOverflow answers. The fix is..." (shows inline)
**Copy an address →** "15 min drive. Want directions?"
**Copy a tracking number →** "FedEx — arriving Thursday. Want a reminder?"
**Copy code →** "This is Python. Want me to explain it / convert to TypeScript / find bugs?"
**Copy an email address →** "Sarah Chen, VP Engineering at Stripe. Last emailed 2 weeks ago."
**Copy a date →** "That's next Thursday. You have 2 conflicts. Want me to find a free slot?"

**Why it goes viral:** It's invisible until it's useful. Every copy becomes a potential action. People will go "wait, it just DID that?" The demo of copying an error and getting an instant fix in the notch is chef's kiss.

**Implementation:** `NSPasteboard` observer → classify content type → route to appropriate mini-agent → show result in notch toast. Most responses in under 1s for classification, 2-3s for actions.

---

## 5. FOCUS/FLOW STATE DETECTOR

The notch knows when you're in the zone and protects you.

**How it detects flow:**
- Sustained typing/mouse activity in a single app for 10+ min
- No app switching
- No Slack/email checks

**What it does:**
- Silently holds notifications
- Shows a subtle breathing animation in the notch (you're in flow, everything's quiet)
- When you break focus, it gives you a debrief: "You were focused for 47 minutes. While you were away: 3 Slack DMs, 1 email from Sarah (she needs the API spec), PR #301 was approved."
- Weekly flow report: "You averaged 2.3 hours of deep work per day. Best day: Wednesday (4.1 hours). Biggest interrupter: Slack."

**Why it goes viral:** Productivity Twitter would eat this alive. The "flow state breathing notch" animation alone would get shared. The weekly report is screenshot bait.

**Implementation:** Track active app via `NSWorkspace`, keystrokes via accessibility APIs, notification suppression via DND API. Lightweight — no AI needed for detection, Claude only for the debrief summary.

---

## 6. "WHAT DID I MISS?" (the 5-second catch-up)

You step away for lunch. You come back. You hover the notch. It tells you everything that happened.

**"You were away for 47 minutes. Here's what happened:"**
- 4 new emails (1 urgent: Sarah needs budget approval by 3pm)
- 6 Slack messages (Jake asked about the deployment, Lisa shared the design mockups)
- PR #287 was merged
- Your Linear ticket was moved to "In Review" by Alex
- Bitcoin dropped 3% (if you care about that)

**Why it goes viral:** Everyone has "return to desk" anxiety. This kills it. One hover, full context, zero scrolling through 6 apps. The demo of "I left for 30 minutes and my notch caught me up in 5 seconds" is extremely shareable.

**Implementation:** Track "away" via screen lock / idle detection. On return, poll all connected services for changes since last active. Feed to Claude: "summarize what changed in the last 47 minutes, prioritize by urgency." Show as a stacked card in the notch.

---

## 7. AGENT PLAYGROUND / COMMUNITY AGENTS

Let people create and share agents as simple config files.

```yaml
name: PR Roaster
trigger: github.pr.opened
prompt: |
  Review this PR diff. Be brutally honest but funny.
  Point out actual issues but make it entertaining.
tools: [github]
output: github.pr.comment
```

```yaml
name: Tweet Drafter
trigger: manual
prompt: |
  Based on what I'm currently working on (check my recent
  git commits and Linear tickets), draft a tweet about
  what I'm building. Keep it authentic, not corporate.
tools: [github, linear]
output: clipboard
```

```yaml
name: Expense Tracker
trigger: clipboard.url.receipt
prompt: |
  Extract the merchant, amount, and date from this receipt.
  Add it to my expenses spreadsheet.
tools: [web_read, google_sheets]
output: notification
```

**Why it goes viral:** Community + creation = virality engine. "Check out this agent I made" → people share configs → others install them → network effect. Think Raycast extensions but for AI agents. A GitHub repo of community agents that you can one-click install into your notch.

**Implementation:** YAML/JSON agent configs loaded from `~/.danotch/agents/`. Backend parses config, wires up triggers and tools. Community repo on GitHub. CLI: `danotch install pr-roaster`.

---

## 8. OPEN SOURCE "REWINDAI FOR AGENTS"

Record everything your agents do. Full audit trail. Search your agent history.

"What did my email agent send last Tuesday?"
"Show me every time an agent accessed my calendar"
"How much have my agents saved me this week?" (estimate time saved per task)

**Why it goes viral:** Rewind.ai proved people want computer memory. This is the same but for your AI agents. Privacy-first (all local), open source, and the "time saved" metric is incredibly shareable. "My notch agents saved me 4.7 hours this week" is a tweet that writes itself.

**Implementation:** SQLite log of all agent actions, tool calls, and results. Local full-text search. Claude summarizes on demand. Time-saved heuristic: estimate manual time for each task type.

---

## The Viral Playbook

**What to build for launch (maximum impact with minimum effort):**

1. **Clipboard agent** — instant wow, zero setup, works immediately after install
2. **Natural language command bar** — the "Spotlight killer" hook, easy to demo
3. **"What did I miss?"** — relatable pain point, great screenshots
4. **System vitals with sparklines** — the notch looks gorgeous, devs share it

**What to show in the demo video (30 seconds):**
- Notch sitting there, minimalist, sparklines pulsing
- Copy an error → notch instantly shows the fix
- `⌘+Shift+Space` → "tell sarah I'll be late" → done
- Come back from lunch → hover → 5-second catchup card
- End card: "Your MacBook notch finally does something."

**What makes people install it:**
- Single `brew install danotch` or drag-to-Applications
- Works immediately with zero config (clipboard agent, system vitals)
- Add API keys later to unlock more (Gmail, Slack, etc.)
- Open source, local-first, no cloud account needed

**What makes people share it:**
- The notch looks stunning (Nothing aesthetic, sparklines, dot grid)
- Time-saved stats ("my notch saved me 3 hours this week")
- Community agents ("check out this agent I made")
- The clipboard magic moments ("it just knew what I meant")

---

## More Ideas (informed by what's actually trending, April 2026)

---

### 9. MCP UNIVERSAL CONNECTOR ("plug into everything instantly")

MCP (Model Context Protocol) has exploded — 34,700+ dependent TS projects, adopted by OpenAI/Google/Microsoft, thousands of MCP servers for databases, APIs, browsers, Zapier (7,000+ actions), Supabase, Firecrawl, etc.

**The idea:** Danotch is an MCP client. Instead of building every integration by hand, you just point it at MCP servers. Want Notion? `danotch add mcp notion`. Want Postgres? `danotch add mcp postgres`. Want Zapier? Instantly get 7,000+ automations.

**What this means:**
- Day 1: connect to any MCP server the community has already built
- No custom tool code per integration — MCP servers handle it
- Users bring their own MCP servers (maybe they already run them for Claude Desktop)
- The notch becomes a universal MCP frontend

**Why it goes viral:** "I connected my notch to 47 tools in 2 minutes." MCP is the hottest protocol in AI right now. Being the best MCP client with the coolest UI (a notch) is a positioning goldmine. Every MCP server announcement on Twitter becomes free marketing for Danotch.

**Implementation:** `@modelcontextprotocol/sdk` in the backend. Config file listing MCP server URIs. Backend discovers available tools from each server, exposes them to the Claude agent. The agent picks the right tool based on the user's request.

```yaml
# ~/.danotch/mcp.yaml
servers:
  - name: notion
    command: npx @notionhq/mcp-server
  - name: github
    command: npx @anthropic/github-mcp-server
  - name: postgres
    uri: stdio://npx @modelcontextprotocol/server-postgres
    env:
      DATABASE_URL: postgres://localhost/mydb
  - name: zapier
    uri: https://actions.zapier.com/mcp
```

---

### 10. GHOST MODE — SCREEN AGENT THAT ACTS FOR YOU

Inspired by Claude Computer Use (launched March 2026, already huge). But instead of taking over your whole screen, the notch observes and acts surgically.

**How it works:**
- You say "fill out this form with my info" → notch watches the screen, identifies form fields, fills them via accessibility APIs or simulated input
- "Book the cheapest flight on this page" → reads the screen, clicks the right option
- "Star all unread emails from the engineering team" → watches Gmail tab, performs bulk action
- "Accept all the suggested changes in this Google Doc" → clicks through them

**The key difference from Claude Computer Use:** It's not a full takeover. It's a notch-sized copilot that does small screen actions while you keep working. Think of it as a cursor that moves on its own to do your bidding while you watch.

**Why it goes viral:** The visual of your mouse moving on its own while the notch shows "Filling form... 3/7 fields done" is mesmerizing. Screen recording of this gets millions of views.

**Implementation:** `CGEvent` for mouse/keyboard simulation, `screencapture` + Claude vision for understanding, accessibility APIs (`AXUIElement`) for reading UI elements. The notch shows a live progress bar of the action sequence.

---

### 11. LOCAL-FIRST AI TERMINAL ("your notch runs code")

A sandboxed terminal that lives in the notch. Ask it anything that requires running code on your machine.

**Examples:**
- "How big is my node_modules across all projects?" → runs `find / -name node_modules -type d 2>/dev/null | xargs du -sh | sort -rh | head -20` → shows results
- "Kill whatever's using port 3000" → finds and kills the process
- "Compress all PNGs in my Downloads folder" → runs ImageMagick/pngquant
- "Show me my git activity this week across all repos" → aggregates git logs
- "What's eating my disk space?" → visual treemap in the notch
- "Set up a new Next.js project called dashboard" → scaffolds it

**Why it goes viral:** Devs LOVE terminal tricks. "I asked my notch to find my biggest node_modules and it found 47GB of dead dependencies" is an instant Twitter banger. The fact that it just runs real commands locally (not some sandboxed playground) makes it genuinely useful.

**Implementation:** Spawn shell processes from the backend, stream output. Claude generates the command, user approves (destructive commands require explicit approval), output summarized and shown in notch. Safety: allowlist safe commands to auto-execute, require approval for `rm`, `kill`, `sudo`, etc.

---

### 12. CONTEXT HANDOFF ("throw it to the notch")

Global shortcut: select any text/image anywhere → `⌘+Shift+D` → it lands in the notch with smart actions.

**Select text in a browser:**
- Article paragraph → "Summarize the full article" / "Save to Notion" / "Tweet this insight"
- Code snippet → "Explain" / "Find bugs" / "Convert to Python"
- Error message → "Debug" / "Search GitHub issues"
- Someone's name → "Who is this? Check LinkedIn/Twitter"

**Select an image:**
- Screenshot of UI → "Roast this design" / "Generate CSS for this" / "File a bug with this screenshot"
- Photo → "Remove background" / "Describe for alt text" / "Reverse image search"
- Chart/graph → "Extract the data" / "Summarize the trend"

**Select a file in Finder:**
- PDF → "Summarize" / "Extract tables to CSV"
- CSV → "Visualize" / "Find anomalies"
- Image → same as above

**Why it goes viral:** The gesture is universal. Select + hotkey = instant AI. No app switching, no pasting into ChatGPT, no context loss. Works with literally anything on your screen. The "select an error → instant fix in the notch" demo is the money shot.

**Implementation:** `NSPasteboard` for text, `screencapturekit` for selected regions, global hotkey via `NSEvent.addGlobalMonitorForEvents`. Content classification → route to mini-agent → show result in notch dropdown.

---

### 13. AMBIENT CODING AGENT ("notch for devs")

The notch monitors your dev environment and helps without asking.

**When you're in VS Code / Cursor:**
- Detects you're stuck (no typing for 30s while staring at code) → "Need help with this function?"
- Sees failing tests in terminal → "2 tests failing. The issue is [concise fix]"
- Notices you're writing the same pattern repeatedly → "Want me to generate the rest?"
- Git conflict detected → "I see the conflict. Here's the merged version."
- Long build running → "Build in progress, ~2 min. Meanwhile, you have 3 review comments on PR #412."
- You switch to browser to look something up → "Looking for [X]? Here's the answer: ..."

**When you push code:**
- "PR #413 created. I drafted a description based on your commits: [preview]. Post it?"
- "CI will take ~8 min. I'll notify you when it passes."
- "Your PR touches the auth module — heads up, Sarah modified it 2 hours ago."

**Why it goes viral:** Every dev wants this. The "notch saw I was stuck and just told me the fix" stories will spread organically. It's GitHub Copilot but ambient — it's watching the whole screen, not just the editor.

**Implementation:** Watch active app (VS Code process), read terminal output via accessibility APIs, monitor filesystem changes in the active project. Periodic screenshot + Claude vision for deeper context. All suggestions non-intrusive — small notch toast that fades if ignored.

---

### 14. SOCIAL PULSE ("your notch knows what's trending")

A background agent that monitors Twitter/X, Hacker News, Reddit, and Product Hunt for things relevant to you.

**Configure your interests:**
- "AI agents", "Swift development", "startup funding", your company name, your product name, competitors

**What the notch shows:**
- Collapsed: small number badge "3 trending" next to the notch
- Expanded: "Trending for you" feed
  - "OpenAI just announced GPT-5 (2.4k tweets in 1 hour)"
  - "Your competitor Acme raised $20M (HN front page)"
  - "Someone mentioned Danotch on Twitter — 47 likes"
  - "New MCP server for Stripe just dropped on GitHub (rising)"

**Smart alerts:**
- "A tweet criticizing your product is going viral (340 RTs). Want to draft a response?"
- "Your blog post hit #3 on Hacker News. 89 comments so far — want a summary?"
- "The React conf keynote just started. Key announcements dropping in the notch as they happen."

**Why it goes viral:** FOMO is the most powerful viral mechanic. "My notch told me about the OpenAI announcement before I saw it on Twitter" is exactly the kind of thing people share. The "someone mentioned you" alert is chef's kiss for founders and devs.

**Implementation:** Twitter/X API v2 (filtered stream + search), HN API (poll front page + algolia search), Reddit API (subreddit monitoring). Run on 60s poll interval. Claude scores relevance and urgency. Only surface genuinely interesting items (anti-noise).

---

### 15. PAIR PROGRAMMING NOTCH ("always-on code buddy")

The notch shows a tiny live context of what your AI coding agent is doing — like a minimap for your AI pair programmer.

**When Claude Code / Cursor background agent is running:**
- Notch shows: current file being edited, lines changed, which tool is running
- Color-coded progress: green (writing code), yellow (reading files), orange (running tests), red (error)
- Click to jump directly to the file/line being modified
- "Agent is editing auth.ts:47 — adding rate limiting middleware"
- "Agent ran tests — 3 passed, 1 failed. Fixing..."

**When you're coding manually:**
- Notch shows: subtle suggestions based on your current file
- "This function is similar to `utils/parse.ts:23` — want to DRY it up?"
- "You've been editing this file for 40 min — want me to write tests for your changes?"

**Why it goes viral:** Every dev using Claude Code or Cursor wants to know what the agent is doing without switching to the terminal. The real-time "agent minimap" in the notch is a genuinely new UX that doesn't exist anywhere. Screenshots of the notch showing agent progress while you work on something else = viral dev content.

**Implementation:** Monitor Claude Code process output, parse structured logs. For Cursor: watch filesystem changes in `.cursor/` directory. For manual coding: periodic file diff + Claude analysis of what the dev is working on.

---

## Updated Viral Playbook

**The nuclear launch combo (pick 3, ship fast):**

| Idea | Viral potential | Effort | Why |
|------|:-:|:-:|-----|
| MCP universal connector | S-tier | Medium | Instant ecosystem, every MCP tweet is free marketing |
| Context handoff (⌘+Shift+D) | S-tier | Low-Medium | Works with everything, demo is irresistible |
| Clipboard agent | A-tier | Low | Zero config wow moment |
| Local AI terminal | A-tier | Low-Medium | Devs share terminal screenshots religiously |
| Social pulse | A-tier | Medium | FOMO drives shares |
| Screen agent (ghost mode) | S-tier | High | The Jarvis moment, but harder to build |
| Pair programming notch | A-tier | Medium | Every Claude Code user wants this |

**The 30-second demo that breaks Twitter:**

1. Notch sitting quiet, minimal sparklines pulsing
2. Copy a stack trace → notch shows the fix in 2 seconds
3. `⌘+Shift+D` on selected text → "Tweet this insight" → done
4. "what's trending in AI right now" → social pulse card appears
5. Notch flashes: "Your PR just passed CI. Ship it?" → one click → deployed
6. End card: **"Your notch. Your agents. danotch.dev"**

**Positioning that wins:**
> "The first AI agent that lives in your MacBook notch. Open source. Local-first. Connects to everything via MCP. Your notch finally does something."
