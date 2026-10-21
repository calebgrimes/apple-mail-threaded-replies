#!/bin/bash
# Claude Code PreToolUse hook on Bash: blocks a "Re:" subject on mail-draft.applescript.
#
# A new-message draft with "Re:" typed into the subject looks like a reply and is
# not one. It carries no In-Reply-To or References header, so the recipient's mail
# cannot thread it. Real replies go through `hmail reply`, which uses Mail's own
# reply command and then proves the headers on disk.

INPUT=$(cat)
# Join backslash-continued lines: grep reads one line at a time, and a staging
# command can put the subject on the line after the script name.
CMD=$(printf '%s' "$INPUT" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command','').replace(chr(92)+chr(10),' '))" 2>/dev/null)
case "$CMD" in
  *mail-draft.applescript*) ;;
  *) exit 0 ;;
esac

# The SUBJECT is the first argument after the script name, quoted or not.
if printf '%s' "$CMD" | /usr/bin/grep -Eiq "mail-draft\.applescript[\"']?[[:space:]\\]+[\"']?[[:space:]]*(re|fwd?|aw)[[:space:]]*:"; then
  cat >&2 << 'MSG'
BLOCKED: "Re:" on a new-message draft makes a fake reply. It has no threading
headers, so the recipient's mail shows it as a new conversation. Stage a real reply:
  hmail reply --subject "<original subject>" --from <sender match> --to <address> --body <file>
It uses Mail's own reply command and checks the threading headers on disk.
See the apple-mail-reply skill.
MSG
  exit 2
fi
exit 0
