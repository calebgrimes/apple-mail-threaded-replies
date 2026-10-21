#!/bin/bash
# Install hmail for your user. This script does three things:
#   1. Link bin/hmail into ~/.local/bin.
#   2. Copy the Claude Code skill into ~/.claude/skills.
#   3. Print the hook setting for you to add to ~/.claude/settings.json.
# It never edits settings.json.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SKILL_DIR="$HOME/.claude/skills"

mkdir -p "$BIN_DIR"
ln -sf "$HERE/bin/hmail" "$BIN_DIR/hmail"
echo "Linked: $BIN_DIR/hmail -> $HERE/bin/hmail"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH. Add it to your shell startup file." ;;
esac

mkdir -p "$SKILL_DIR"
rm -rf "$SKILL_DIR/apple-mail-reply"
cp -R "$HERE/claude/skills/apple-mail-reply" "$SKILL_DIR/apple-mail-reply"
echo "Copied skill: $SKILL_DIR/apple-mail-reply"

cat <<JSON

Add this hook to ~/.claude/settings.json (merge it into an existing "hooks" key):

{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "$HERE/claude/hooks/fake-reply-gate.sh" }
        ]
      }
    ]
  }
}

Then give your terminal app two permissions in System Settings > Privacy & Security:
  - Accessibility
  - Automation (control of Mail and System Events)
JSON
