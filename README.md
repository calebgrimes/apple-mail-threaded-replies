# Apple Mail threaded replies for AI agents

By Caleb Grimes. MIT license.

## 1. What it does

This repo lets a script or an AI agent put a real, threaded reply into the Drafts folder of Apple Mail. It does not send anything. After it saves the draft, it reads the saved file from disk and proves three things: the draft is threaded, the body landed, and the recipient is the address you intended. It also has a hook and a skill for Claude Code, and a field guide to the many ways that Mail automation fails without any error. The guide is below.

Quick start:

```
./install.sh
echo "Thanks, that works for me." > /tmp/body.txt
hmail reply --subject "Original subject" --from sender@example.com --to client@example.com --body /tmp/body.txt
```

Each result line starts with a shape and a word: `✔` (good), `✖` (stop), `◐` (wait). Use `hmail check "Re: Original subject" --to client@example.com` to check any reply draft.

## 2. The bugs and traps we found

Each item gives the symptom, the cause, and the fix. All of these cost real time. Most of them fail without any error message.

### The body hides behind "show trimmed content"

- Symptom: The recipient opens your message in Gmail or iOS Mail and sees an empty message. The text is behind "show trimmed content" or "show history".
- Cause: In Apple Mail 16 (macOS 15.4), the AppleScript `content` property wraps the body in `<blockquote type="cite">`. Gmail and iOS read that tag as quoted history and collapse it. The same write path also fails to commit at times, and it sometimes duplicates the first line.
- Fix: Do not use `content`. Put HTML on the clipboard and paste it into the compose window. `lib/text-to-mail-html.py` makes the HTML in the same shape that Mail writes when you type.

### The reply draft disappears after "close saving yes"

- Symptom: `close <reply> saving yes` returns success. No draft exists afterward.
- Cause: On an Exchange account, the AppleScript verb discards the reply and still reports success.
- Fix: Send a real Cmd+S keystroke to the window, wait for the Exchange round trip, then send Cmd+W.

### The paste lands in the To: field

- Symptom: The body is empty. The address field holds strange text.
- Cause: A fresh compose window puts focus on the To: field.
- Fix: Set focus on the body first. The body is the `AXScrollArea` inside two `AXGroup` elements.

### The paste lands nowhere after a recipient edit

- Symptom: You set the recipients, then you paste, and the body is empty.
- Cause: Editing recipients resets the editing state of the compose window.
- Fix: Paste first. Edit the recipients after the paste, never before.

### Attachments re-wrap the body

- Symptom: The attachment works, but the body now has the quote wrapper again.
- Cause: The AppleScript attachment verb writes through `content`.
- Fix: Use the menu File > Attach Files. In the file panel, press Cmd+Shift+G and paste the path into the Go To Folder field. Do not type the path. Go To Folder autocompletes while you type, and it breaks paths with spaces. Wait for each panel to appear before you press a key. Fixed delays dropped about one attachment in three.
- Also check the result. `lib/verify-draft-attachments.py` compares the draft size with the file sizes and counts the attachment parts.

### "content" reads 0 and the draft looks empty

- Symptom: `content of <outgoing message>` returns an empty string for a body that you pasted.
- Cause: A pasted body does not show up in that property.
- Fix: Treat the saved `.emlx` file as the only honest witness. Exchange writes that file late, sometimes minutes late, so poll for it. Do not delete a draft because one early check failed. `lib/verify-draft-body.py` does this check. It also looks for a distinctive phrase from your body (the "needle"), because the quoted history of a reply is long enough to pass a length check alone.

### A false failure deletes good drafts

- Symptom: Every attempt fails, and the retry logic deletes drafts that were fine.
- Cause: The needle did not match. A needle from a line that starts with a bullet, a line with parentheses, or a line with a bare URL does not appear in the rendered HTML in the same form.
- Fix: `lib/body-needle.py` strips list markers and emphasis, and it skips lines with links. On the last attempt, leave the draft in place. A draft you can read is worth more than a tidy Drafts folder.

### The paste fails when the screen is locked

- Symptom: The script runs, and nothing lands.
- Cause: Keystrokes and paste do not reach Mail while the screen is locked.
- Fix: Check the console lock state before you start. `hmail` reads it from `ioreg`.

### Mail is suspended or wedged

- Symptom: "The panel never opened." The script waits and fails.
- Cause one: The Mail process is suspended (`ps` shows STAT `T`). Run `kill -CONT <pid>`.
- Cause two: Mail is wedged. It has windows, but it reports zero outgoing messages. Choose Window > New Viewer Window in Mail to clear the wedge.
- Fix: `hmail` checks the process state before it starts. A retry loop will not help here. Read the error first.

### Address autocomplete replaces the recipient

- Symptom: The saved draft goes to a different address than the one you set.
- Cause: Autocomplete can replace a recipient. Three causes are known: a stray keystroke, two agents that stage at the same time, and an old entry in Previous Recipients.
- Fix: Read the saved `To:` header and compare it with the address you intended. `hmail` does this. It flags a display name in the header as `HIJACKED`, because autocomplete adds a name when it changes the address. Known false alarm: Mail can also add a Contacts name to a correct address when it saves. The check fails safe, so a false alarm stops a good draft but never passes a bad one. Read the address in the line before you discard the draft.

### A typed name resolves to the wrong address

- Symptom: A draft goes to a no-reply robot address, not to the person.
- Cause: The address store of Mail maps a display name to every address it has seen with that name. That includes no-reply robots from booking services.
- Fix: Never type a name. Take the address from your own trusted record and pass the bare address.

### A fake reply does not thread

- Symptom: The draft has "Re:" in the subject. The recipient sees a new conversation.
- Cause: Threads use the `In-Reply-To` and `References` headers. A "Re:" subject alone does nothing. A new message with a typed "Re:" subject carries neither header.
- Fix: Use the `reply` verb of Mail itself, so Mail writes the headers. Then read the saved draft and check that `In-Reply-To` names a real message in the thread and that `References` contains it. `hmail reply` and `hmail check` do this.

### A prepared .eml opens read-only

- Symptom: You build a message file with the right headers. Mail opens it, and you cannot edit it.
- Cause: Opening a prepared `.eml` file opens a read-only viewer, not an editable draft. This holds even with `X-Unsent: 1`.
- Fix: Do not build `.eml` files for this. Use the `reply` verb.

### Deleting drafts does nothing

- Symptom: `delete` on a draft returns, and the draft is still there.
- Cause: AppleScript `delete` on drafts often does nothing and raises no error. Deleting from the list you are looping over also skips items.
- Fix: Collect the drafts first, then delete them. List again to confirm that they are gone.

### Two staging jobs corrupt each other

- Symptom: The wrong text lands in a draft. Or a recipient changes.
- Cause: The clipboard and the front window are shared. Two jobs that stage at once fight over both.
- Fix: Staging is single-writer. `hmail` takes a lock file (`~/Library/Caches/hmail/mail-staging.lock`) and refuses to run if another process holds it. Do not copy anything while a job runs. A clipboard copy during a run once put a spreadsheet cell into a draft. That is why the needle check exists.

### Drafts with the same subject collide

- Symptom: A batch job finishes one draft, and its retry cleanup deletes it.
- Cause: The cleanup matched on subject alone. Different people can get the same subject.
- Fix: Match on subject and recipient together.

## 3. Using it with Claude Code

`install.sh` does three things. It links `bin/hmail` into `~/.local/bin`. It copies the skill to `~/.claude/skills/apple-mail-reply`. It prints a hook setting. You add the hook to `~/.claude/settings.json` by hand. The script never edits that file.

- The skill (`claude/skills/apple-mail-reply/SKILL.md`) tells the agent to use `hmail reply` for any email that continues a conversation, and how to read the result.
- The hook (`claude/hooks/fake-reply-gate.sh`) is a PreToolUse hook for Bash. It blocks `mail-draft.applescript` when the subject starts with "Re:", "Fwd:", or "Aw:". The agent gets a message that names the right command.

## 4. Safety

Nothing here can send mail. No script calls a send verb. Every result is a draft in the Drafts folder. A human reviews and sends it. `hmail` also prints `DO NOT SEND` when a recipient check fails.

## 5. Requirements

- macOS 15 or newer
- Apple Mail
- python3
- Accessibility and Automation permissions for your terminal app (System Settings > Privacy & Security)

Optional: set `HMAIL_MAIL_MCP` to the path of a `mail-mcp` tool (for example [dastrobu/mail-mcp](https://github.com/dastrobu/mail-mcp)). The verify scripts then use it as a second check when Exchange has not written the draft file yet. The default is `/opt/homebrew/opt/mail-mcp/bin/mail-mcp`. Everything works without it.

## 6. Status

We tested this on one Mac, with one Exchange account and some Gmail accounts. Expect differences in UI timing on other setups. Delays in the AppleScript files may need tuning. The window layout may change in other versions of Mail.

## Layout

```
bin/hmail                         the reply and check command
applescript/mail-reply.applescript   threaded reply draft
applescript/mail-draft.applescript   new-message draft, with attachments
lib/                              HTML conversion and the three verifiers
claude/                           Claude Code hook and skill
install.sh
```
