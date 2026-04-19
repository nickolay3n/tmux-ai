#!/bin/bash

# ============================================================================
# AI-Assisted Terminal - installer
# ============================================================================

set -euo pipefail
umask 077

# ============================================================================
# CONFIG
# ============================================================================

NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
BASE_SESSION_NAME="ai-workspace"
API_MODEL="meta/llama-3.3-70b-instruct"
API_MAX_TOKENS=500
API_TEMPERATURE=0.1
MAX_OUTPUT_LENGTH=2000

RUNTIME_DIR="/tmp/tmux-ai"
ANALYZE_SCRIPT="$RUNTIME_DIR/analyze-command.sh"
LEFT_PANE_BASHRC="$RUNTIME_DIR/left-pane-bashrc"
RIGHT_PANE_INIT="$RUNTIME_DIR/right-pane-init.txt"
TMUX_AI_CONF="$HOME/.tmux-ai.conf"
TMUX_CONF="$HOME/.tmux.conf"
BASHRC_FILE="$HOME/.bashrc"
ZSHRC_FILE="$HOME/.zshrc"
BASHRC_START="# >>> tmux-ai function >>>"
BASHRC_END="# <<< tmux-ai function <<<"

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

# ----------------------------------------------------------------------------
# NVIDIA_API_KEY: prompt if unset (hidden input; not written to shell history)
# ----------------------------------------------------------------------------

prompt_nvidia_api_key() {
    if [ -n "${NVIDIA_API_KEY:-}" ]; then
        export NVIDIA_API_KEY
        return 0
    fi
    local tty=/dev/tty
    echo "NVIDIA_API_KEY is not set." >&2
    echo "Enter your key below. Input is hidden and is not stored in command history." >&2
    if [ ! -c "$tty" ]; then
        echo "ERROR: cannot prompt (no TTY). Set NVIDIA_API_KEY in the environment, e.g." >&2
        echo "  export NVIDIA_API_KEY='...'" >&2
        echo "  ./setup-ai-tmux.sh" >&2
        exit 1
    fi
    printf "NVIDIA API key: " >"$tty"
    read -r -s NVIDIA_API_KEY <"$tty" || true
    echo "" >"$tty"
    # strip CR if pasted from Windows
    NVIDIA_API_KEY="${NVIDIA_API_KEY//$'\r'/}"
    if [ -z "$NVIDIA_API_KEY" ]; then
        echo "ERROR: empty API key." >&2
        exit 1
    fi
    export NVIDIA_API_KEY
}

prompt_nvidia_api_key

# ============================================================================
# CHECKS
# ============================================================================

for cmd in tmux jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is not installed"
        exit 1
    fi
done

HAS_XCLIP=0
if command -v xclip >/dev/null 2>&1; then
    HAS_XCLIP=1
else
    echo "WARN: xclip is not installed, clipboard integration in tmux will be limited"
fi

echo "OK: dependency checks passed"

# ============================================================================
# SESSION NAME (DO NOT KILL EXISTING SESSION)
# ============================================================================

SESSION_NAME="$BASE_SESSION_NAME"
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    SESSION_NAME="${BASE_SESSION_NAME}-$(date +%H%M%S)"
    echo "WARN: session '$BASE_SESSION_NAME' already exists, using '$SESSION_NAME'"
fi

# ============================================================================
# ANALYZER SCRIPT (OVERWRITTEN ON EACH SETUP RUN)
# ============================================================================

cat > "$ANALYZE_SCRIPT" << EOF
#!/bin/bash
set -euo pipefail

NVIDIA_API_KEY="\${NVIDIA_API_KEY:-}"
API_MODEL="$API_MODEL"
API_MAX_TOKENS=$API_MAX_TOKENS
API_TEMPERATURE=$API_TEMPERATURE
MAX_OUTPUT_LENGTH=$MAX_OUTPUT_LENGTH
RUNTIME_DIR="$RUNTIME_DIR"

COMMAND="\${1:-}"
OUTPUT="\${2:-}"
TIMESTAMP="\${3:-\$(date +%H:%M:%S)}"

if [ -z "\$NVIDIA_API_KEY" ]; then
    echo "WARN: NVIDIA_API_KEY is not set, analysis skipped."
    exit 0
fi

if [ \${#OUTPUT} -gt \$MAX_OUTPUT_LENGTH ]; then
    OUTPUT="\${OUTPUT:0:\$MAX_OUTPUT_LENGTH}\n\n... (output truncated, max \$MAX_OUTPUT_LENGTH chars)"
fi

ESCAPED=\$(printf '%s' "Command: \$COMMAND\n\nOutput:\n\$OUTPUT" | jq -Rs .)

HTTP_RESPONSE=\$(mktemp "\$RUNTIME_DIR/api-response.XXXXXX")
HTTP_CODE=\$(curl -sS --max-time 100 --retry 2 --retry-delay 1 -w "%{http_code}" -o "\$HTTP_RESPONSE" https://integrate.api.nvidia.com/v1/chat/completions -H "Authorization: Bearer \$NVIDIA_API_KEY" -H "Content-Type: application/json" -d "{
        \"model\": \"\$API_MODEL\",
        \"messages\": [{\"role\": \"user\", \"content\": \$ESCAPED}],
        \"max_tokens\": \$API_MAX_TOKENS,
        \"temperature\": \$API_TEMPERATURE
    }")

if [ "\$HTTP_CODE" -lt 200 ] || [ "\$HTTP_CODE" -ge 300 ]; then
    RESULT="API error (HTTP \$HTTP_CODE): \$(jq -r '.error.message // "unknown error"' "\$HTTP_RESPONSE" 2>/dev/null || echo "cannot parse error body")"
else
    RESULT=\$(jq -r '.choices[0].message.content // .error.message // "empty API response"' "\$HTTP_RESPONSE" 2>/dev/null || echo "JSON parse error")
fi
rm -f "\$HTTP_RESPONSE"

RESULT_FILE=\$(mktemp "\$RUNTIME_DIR/ai-result.XXXXXX")
{
    echo "======================================================================"
    echo "AI ANALYSIS"
    echo "Command: \$COMMAND"
    echo "Time:    \$TIMESTAMP"
    echo "----------------------------------------------------------------------"
    printf '%s\n' "\$RESULT"
    echo "======================================================================"
} > "\$RESULT_FILE"

# Target right pane: must include session name (background job is not ambiguous about session)
if [ -n "\${TMUX:-}" ]; then
    _TMUX_AI_PANE=\$(tmux display-message -p '#{session_name}:main.1' 2>/dev/null || true)
    if [ -n "\$_TMUX_AI_PANE" ] && tmux display-message -t "\$_TMUX_AI_PANE" -p '' >/dev/null 2>&1; then
        tmux send-keys -t "\$_TMUX_AI_PANE" C-l
        tmux send-keys -t "\$_TMUX_AI_PANE" "cat '\$RESULT_FILE'; rm -f '\$RESULT_FILE'; echo ''" C-m
    else
        cat "\$RESULT_FILE"
        rm -f "\$RESULT_FILE"
    fi
else
    cat "\$RESULT_FILE"
    rm -f "\$RESULT_FILE"
fi
EOF
chmod 700 "$ANALYZE_SCRIPT"
echo "OK: analyzer script updated: $ANALYZE_SCRIPT"

# ============================================================================
# UPDATE ~/.bashrc and ~/.zshrc (if present) — same block, replaced each run
# ============================================================================

inject_ai_block_into_rc() {
    local rc_file="$1"
    local tmp
    tmp="$(mktemp "$RUNTIME_DIR/rc.XXXXXX")"
    if [ -f "$rc_file" ]; then
        awk -v start="$BASHRC_START" -v end="$BASHRC_END" '
            $0 == start {skip=1; next}
            $0 == end   {skip=0; next}
            !skip       {print}
        ' "$rc_file" > "$tmp"
    else
        : > "$tmp"
    fi

    cat >> "$tmp" << EOF
$BASHRC_START
ai() {
    local cmd="\$*"
    if [ -z "\$cmd" ]; then
        echo "Usage: ai <command>"
        return 0
    fi

    local output exit_code timestamp
    output=\$("\$@" 2>&1)
    exit_code=\$?
    printf '%s\n' "\$output"

    if [ -n "\$output" ] || [ \$exit_code -ne 0 ]; then
        timestamp=\$(date +%H:%M:%S)
        if [ -x "$ANALYZE_SCRIPT" ]; then
            "$ANALYZE_SCRIPT" "\$cmd" "\$output" "\$timestamp" &
        else
            echo "WARN: analyzer script not found: $ANALYZE_SCRIPT"
            echo "      Run setup-ai-tmux.sh again."
        fi
    fi

    return \$exit_code
}
alias a=ai
$BASHRC_END
EOF

    mv "$tmp" "$rc_file"
}

inject_ai_block_into_rc "$BASHRC_FILE"
echo "OK: ai() function has been written to $BASHRC_FILE"

# Same block in ~/.zshrc so zsh users get `ai` even if ~/.zshrc did not exist before.
inject_ai_block_into_rc "$ZSHRC_FILE"
echo "OK: ai() function has been written to $ZSHRC_FILE"

# ============================================================================
# LEFT PANE RC
# ============================================================================

cat > "$LEFT_PANE_BASHRC" << EOF
source "$BASHRC_FILE"
echo ""
echo "======================================================================"
echo "AI-ASSISTED TERMINAL"
echo "Use: ai <command> or a <command>"
echo "Analysis runs in background and appears in the right pane."
echo "======================================================================"
echo ""
EOF
chmod 700 "$LEFT_PANE_BASHRC"

# ============================================================================
# RIGHT PANE INIT
# ============================================================================

cat > "$RIGHT_PANE_INIT" << 'EOF'
======================================================================
AI ANALYSIS PANEL (ASYNC)
Waiting for commands...

Run in the left pane:
  ai ls -la
  ai df -h
  ai docker ps
======================================================================
EOF
chmod 600 "$RIGHT_PANE_INIT"

# ============================================================================
# TMUX CONFIG (DO NOT OVERWRITE ~/.tmux.conf)
# ============================================================================

cat > "$TMUX_AI_CONF" << EOF
# tmux-ai generated file (overwritten on every setup run)
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
set -g set-clipboard on
setw -g mode-keys vi
bind -n MouseDrag1Border resize-pane -M
bind-key -n C-Left select-pane -L
bind-key -n C-Right select-pane -R
bind-key -n C-Up select-pane -U
bind-key -n C-Down select-pane -D
bind-key -r H resize-pane -L 10
bind-key -r J resize-pane -D 10
bind-key -r K resize-pane -U 10
bind-key -r L resize-pane -R 10
set -g status-left "[#S] "
set -g status-right "#{pane_index} | %H:%M"
set -g status-style "bg=black,fg=white"
set -g pane-border-style "fg=white"
set -g pane-active-border-style "fg=green"
set -sg escape-time 50
setw -g aggressive-resize on
set -g bell-action none
set -g visual-bell off
EOF

if [ "$HAS_XCLIP" -eq 1 ]; then
cat >> "$TMUX_AI_CONF" << 'EOF'
bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -i"
bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -i"
bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -i"
unbind -n MouseDown3Pane
bind -n MouseDown3Pane run "tmux set-buffer \"$(xclip -o -selection clipboard 2>/dev/null)\" 2>/dev/null; tmux paste-buffer 2>/dev/null"
bind-key y run "tmux save-buffer - | xclip -selection clipboard -i 2>/dev/null"
EOF
fi

if [ ! -f "$TMUX_CONF" ]; then
    touch "$TMUX_CONF"
fi

if ! grep -Fq "source-file $TMUX_AI_CONF" "$TMUX_CONF"; then
    printf "\n# tmux-ai\nsource-file %s\n" "$TMUX_AI_CONF" >> "$TMUX_CONF"
fi

# ============================================================================
# CREATE SESSION (child panes inherit exported NVIDIA_API_KEY from this shell)
# ============================================================================

tmux new-session -d -s "$SESSION_NAME" -n main
tmux split-window -h -t "$SESSION_NAME:main"
tmux send-keys -t "$SESSION_NAME:main.0" "bash --rcfile '$LEFT_PANE_BASHRC'" C-m
tmux send-keys -t "$SESSION_NAME:main.0" "clear" C-m
tmux send-keys -t "$SESSION_NAME:main.1" "clear" C-m
tmux send-keys -t "$SESSION_NAME:main.1" "cat '$RIGHT_PANE_INIT'; echo ''" C-m
tmux source-file "$TMUX_AI_CONF"
tmux select-pane -t "$SESSION_NAME:main.0"

echo ""
echo "OK: setup completed"
echo "Session: $SESSION_NAME"
echo "Optional: export NVIDIA_API_KEY before running (or use the prompt when unset)."
echo "Reload shell config: source ~/.bashrc   # bash"
echo "                    or source ~/.zshrc    # zsh"
echo ""

tmux attach -t "$SESSION_NAME"
