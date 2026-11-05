# Deskverse (EOU): agent instructions

One instruction file for every agent here. Claude Code reads it through `CLAUDE.md`, which is a link to this file; edit this file, never the link.

## What Deskverse is

Deskverse (the folder and bundle are still called EOU; renaming the bundle id would reset macOS permissions and saved desks) is a native macOS app that keeps every desk you have ever worked at and lays one out again when you ask. A desk is everything open for one piece of work: Chrome tabs, Claude Code sessions, Obsidian notes, Finder folders, the music playing. EOU saves desks by itself, groups them by topic, and a hotkey panel (like Spotlight, default Shift+Command+Space) finds a desk, or anything open right now, and brings it back.

Origin: Hao's note of 2026-11-05 (`research/hao-note-2026-11-05.md`): "desk is like the working memory for humans, and those are tabs on the computer ... you can have infinite parallel universes for your desk ... say: I have worked on the xx research before, bring this to my desk". The research behind it is in `research/Open loops and AI 2026-11-05/` (note, `report.html`, notes A to F).

## Product rules (each comes from the research)

1. **Zero filing.** Capture and grouping happen by themselves. Forty years of desk systems died because users had to define and maintain the desks (Arc: 5.52% of daily users kept a second Space). Never add a step that asks the user to organise.
2. **Prove the way back before closing anything.** People close only when they trust the return. Until restore has been shown to work for weeks, EOU never quits an app, closes a tab or ends a session. "Put away" only saves and hides windows, which Command+Tab undoes.
3. **Every desk keeps a receipt.** Each saved desk lists what it could not capture (scroll positions, form text, the state of plain shell tabs, Chrome profiles). Never imply a perfect restore.
4. **Agent sessions are restored, not duplicated.** A Claude Code session still running is focused, not resumed a second time. A stopped one comes back with `claude --resume <id>` in its own folder.
5. **Local and private.** The only network call is to Ollama on `127.0.0.1`. AI runs on this Mac: Meta's Llama 3.2 3B (open weights, through Ollama, `MetaModel.swift`) names unlabelled groups and matches sentences to desks; Apple's Foundation Models is the fallback only when Ollama is not running; NaturalLanguage breaks ties. Incognito windows are never captured. Data lives in `~/Library/Application Support/EOU/`.
   - Llama rules from tests on 2026-11-05: describe each desk by what was on it and constrain the answer to real desk names (4 of 4 right); never ask for a bare number (1 of 4). "No match" is final: ask twice with the desk list reversed and accept only an answer that survives (a strict yes/no check rejected everything). The model runs only when keywords find nothing, so a demo sentence that shows Llama must share no words with the desk.
6. **Grouping comes from evidence, the model only names.** The on-device model is poor at sorting items into topics (tested 2026-11-05: it filed a Netflix episode under a research topic). Topics come from signals: a Claude session's folder, a note's folder, the Chrome window a tab sits in, keywords shared with project names. The model names groups that have no project name.
7. **No interruptions.** No notifications in v0. The panel appears only when called.
8. **Minimal by design (Hao, 2026-11-05: "minimalistic by design in late Nov 2026, low mental load").** The panel opens on one question ("What were you working on?") and at most five desks with real work on them. Actions (save, put away, everything) appear only when typed. Rows carry an icon, a title and one line; no labels, badges or counters beyond that.
9. **EOU never moves, edits or deletes files.** It only reads what is open and opens or shows it again.

## macOS Desktops (Spaces)

Design (Hao, 2026-11-05): every desk you bring back starts on a blank workspace. A desk is EOU's own saved object; macOS Desktops are where it is shown.

- Bringing a desk back first saves the desk you are leaving, then moves right through your existing Desktops (Control+Right, the standard "Move right a space" shortcut) until one has no windows (`Spaces.swift`). If none is empty, it hides every window on the current one, then restores. Needs Accessibility (shared with the layout step).
- Apple has no public API to create Desktops. Mission Control's "+" button is not exposed to Accessibility on macOS 27 (tested 2026-11-05, also with the pointer hovering the Spaces bar), and yabai's way needs SIP partly off. So you keep a few empty Desktops (Mission Control, +), and EOU fills them.
- Desktop files: macOS shows the one `~/Desktop` folder on every Desktop. EOU never moves files, so a blank look comes from System Settings, Desktop & Dock, "Show Items: On Desktop" off. The files stay where they are.
- Isolation needs System Settings, Desktop & Dock, "When switching to an application, switch to a Space with open windows" off; otherwise opening Chrome or Obsidian jumps back to their old Desktop.
- Notes open with Obsidian's `paneType=window`, so a note gets its own window on the new Desktop.

## Layout

- `app/`: Swift package (Swift 6.4 toolchain, Swift 5 language mode, macOS 26+). `Sources/EOU/`:
  - `Entry.swift`: entry point; `--dry-run` prints a capture as JSON without UI.
  - `AppDelegate.swift`: menu bar item, hotkey, auto-capture timer.
  - `HotKey.swift`: Carbon global hotkey.
  - `Models.swift`: `DeskItem`, `Snapshot`, `TopicDesk`.
  - `Capture.swift`: collectors (Chrome, Claude Code sessions, Obsidian, Finder, Spotify, apps).
  - `Topics.swift`: evidence-based grouping and on-device naming.
  - `MetaModel.swift`: Meta's Llama 3.2 3B through Ollama on localhost.
  - `Layout.swift`: lays a restored desk out (Accessibility).
  - `Spaces.swift`: finds an empty macOS Desktop for a restored desk.
  - `Profile.swift`: profiles. "main" sees everything; a named profile ("demo") has its own desks folder and a `scope.json`.
  - `Store.swift`: snapshots on disk and the desk index.
  - `Restore.swift`: bring items back, focus live ones, hide windows.
  - `Search.swift`: ranking desks, live items and files.
  - `Launcher.swift`: the panel (Liquid Glass, app-icon desk rows, the "Left off" line) and its SwiftUI view.
  - `Toast.swift`: the quiet confirmation after a bring-back or put away.
- `app/Info.plist`, `app/EOU.entitlements`, `app/Resources/EOU.icns`: bundle metadata, the Apple Events entitlement, the icon (three desks, the one you are on in the panel's selection blue; drawn in code).
- `scripts/build.sh`: builds `build/EOU.app` and signs it with the local Apple Development identity (stable signature, so macOS keeps the permissions between builds).

## Build, run, check

- Build: `scripts/build.sh`. Run: `open build/EOU.app`. First run asks for Automation permission for Chrome, iTerm2, Finder and Spotify, one prompt each.
- Dry run without UI: `build/EOU.app/Contents/MacOS/EOU --dry-run` (from a terminal, Automation is attributed to the terminal, so Chrome and Finder may fail there; that is expected). `--dry-run --selftest` checks grouping on a made-up desk; `--dry-run --ask "a sentence"` runs the sentence matcher against the saved desks.
- Needs: Ollama running with `llama3.2:3b` (`ollama pull llama3.2:3b`), Accessibility for EOU, Automation for Chrome, iTerm2, Finder and Spotify.
- Two Chrome apps can run at once (the CDP Chrome on port 9222 that automation tools use). EOU talks to the person's own Chrome by process id (ScriptingBridge) and opens tabs with Chrome's `--new-window`, never `tell application "Google Chrome"`, which can reach the automation copy.
- Data: `~/Library/Application Support/EOU/snapshots/*.json`.

## Rules

- No em dashes or double hyphens in anything a person reads (UI text, docs, replies).
- Native macOS look: system fonts, system materials, SF Symbols, standard keyboard behaviour. No web views.
- Commit only when Hao asks; never push without him. If this becomes a git repo with a remote, private files stay out of git (see `.gitignore`: Hao's personal baseline, screenshots and note).
- Spending money (paid APIs, an Apple Developer Program change) needs Hao's go-ahead first.

## Profiles

"main" sees everything. A named profile (for example "demo", used to record the demo video without showing private windows) keeps its own saved desks and a `scope.json` in `~/Library/Application Support/EOU/profiles/<name>/`: which agent folders, Obsidian vaults, Chrome pages (`chromeOnlyURLsStartingWith`: a window counts only if every tab is allowed) and apps it may see, and whether it saves by itself. Switch from the menu bar or with `--profile <name>`.

Local-only status notes for this Mac (settings, recording setup, test logs) are in `docs/private/status.md`, which is not in git. Read it when working on this machine.
