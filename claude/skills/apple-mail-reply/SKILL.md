---
name: apple-mail-reply
description: Stage a REAL threaded reply draft in Apple Mail, and check that a reply draft is threaded. Use when the user says "reply to", "draft a reply", "stage a reply", "follow up on that thread", or "answer this email", or whenever the email being drafted continues an existing conversation. Also use to check a draft that has "Re:" in its subject. NOT for a brand-new email with no earlier message, and never for sending.
---

# Apple Mail threaded replies

A reply threads by its `In-Reply-To` and `References` headers. "Re:" in the subject does not
thread it. A new draft with a typed "Re:" subject is a fake reply: the recipient sees a new
conversation. The `fake-reply-gate.sh` hook blocks that pattern.

## Stage a reply

1. Write the body to a UTF-8 file. Plain text or light markdown is fine.
2. Get the recipient address from your own trusted record, never from a typed name.
   A name can resolve to the wrong address, such as a no-reply robot.
3. Run one command:

```
hmail reply --subject "<subject of the message you answer>" --from <text in its sender> --to <address> --body <file>
```

- `--subject` is the original subject. A leading "Re:" is fine either way.
- `--from` matches the sender of the message you answer, such as an address or a domain.
- Add `--all` only on purpose. Old threads carry CC'd people who may have left.

`hmail` checks first that Mail is awake, the screen is unlocked, no compose window is open,
and no other process is staging mail. Mail comes to the front for a few seconds. Do not type
during that time.

## Read the result

Each line starts with a shape and a word:

- `✔ THREADED` means the draft names the message it answers.
- `✔ RECIPIENT` means the To: address is exactly the one you gave.
- `✖ NOT THREADED`, `✖ WRONG RECIPIENT`, or `✖ HIJACKED` means stop. Tell the user not to send that draft.
- `◐ WAITING` means Exchange has not written the draft file yet. Run the `hmail check` line it prints a few minutes later.

`✖ HIJACKED` can be a false alarm. Mail sometimes adds a Contacts name to a correct address.
Show the user the line and let them decide. Do not edit hmail to relax the check.

## Check any reply draft

```
hmail check "Re: <subject>" --to <address>
```

## Rules

- If staging fails, do not run it again. Read the error first. The README of this project lists
  the known causes: Mail suspended, screen locked, Mail wedged, or a compose window left open.
- Nothing sends. Every reply lands in Drafts for the user to review.
- Run only one staging job at a time. The clipboard is shared.
