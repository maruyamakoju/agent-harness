#!/usr/bin/env bash
# =============================================================================
# block-dangerous.sh - PreToolUse Hook for Claude Code
#
# Receives tool invocation as JSON on stdin.
# Exit codes:
#   0 = allow the tool call
#   2 = block the tool call (Claude Code will show the error message)
#
# JSON input format: {"tool_name": "Bash", "tool_input": {"command": "..."}}
# =============================================================================
set -euo pipefail

LOG_FILE="${HARNESS_DIR:-/harness}/logs/hook-blocks.jsonl"

# Read the hook payload from stdin
PAYLOAD=$(cat)

# Extract tool name
TOOL_NAME=$(echo "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null)

# Only inspect Bash tool calls
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Extract the command string from tool_input
COMMAND=$(echo "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)

# If no command, allow
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Normalize: lowercase for case-insensitive matching
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Block function: log and reject
# ---------------------------------------------------------------------------
block_command() {
    local category="$1"
    local pattern="$2"

    # Log the block event
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn \
        --arg ts "$timestamp" \
        --arg cat "$category" \
        --arg pat "$pattern" \
        --arg cmd "$COMMAND" \
        '{timestamp:$ts, category:$cat, pattern:$pat, blocked_command:$cmd}' \
        >> "$LOG_FILE" 2>/dev/null || true

    # Output error message for Claude Code
    echo "BLOCKED: Command rejected by security hook. Category: ${category}. Matched pattern: '${pattern}'. This command is not allowed in the agent sandbox." >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Pattern checks by category
# ---------------------------------------------------------------------------

# === Filesystem Destruction ===
echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)?/' && block_command "FS_DESTRUCTION" "rm -rf /"
# Also catch rm -rf $HOME, rm --recursive --force $HOME, rm -rf ~, etc.
echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f?[a-zA-Z]*|--recursive|--force)\s+(/|\*|~|\$HOME|\$\{HOME\}|"~"|"\$HOME")' && block_command "FS_DESTRUCTION" "rm -rf critical_path"
echo "$COMMAND" | grep -qiE 'rm\s+(-[a-zA-Z]*|--(recursive|force|no-preserve-root)\s+)*\s*(--\s*)?(/|\$HOME|\$\{HOME\}|~)' && block_command "FS_DESTRUCTION" "rm critical path variant"
echo "$COMMAND" | grep -qiE 'mkfs\.' && block_command "FS_DESTRUCTION" "mkfs"
echo "$COMMAND" | grep -qiE 'dd\s+if=.*\s+of=/dev/' && block_command "FS_DESTRUCTION" "dd to device"
echo "$COMMAND" | grep -qiE '(shred|wipefs)\s' && block_command "FS_DESTRUCTION" "disk wipe"
echo "$COMMAND" | grep -qE '>\s*/dev/sd' && block_command "FS_DESTRUCTION" "overwrite device"

# === Remote Code Execution ===
echo "$COMMAND" | grep -qiE 'curl\s.*\|\s*(ba)?sh' && block_command "REMOTE_CODE_EXEC" "curl pipe to shell"
echo "$COMMAND" | grep -qiE 'wget\s.*\|\s*(ba)?sh' && block_command "REMOTE_CODE_EXEC" "wget pipe to shell"
echo "$COMMAND" | grep -qiE 'curl\s.*\|\s*python' && block_command "REMOTE_CODE_EXEC" "curl pipe to python"
echo "$COMMAND" | grep -qiE 'wget\s.*\|\s*python' && block_command "REMOTE_CODE_EXEC" "wget pipe to python"
# Bypass: backtick/subshell RCE: sh `curl ...` or sh $(curl ...)
echo "$COMMAND" | grep -qiE '(ba)?sh\s+[\`\$\(]' && block_command "REMOTE_CODE_EXEC" "shell subshell exec"
echo "$COMMAND" | grep -qiE '(eval|exec)\s+[\`\$\(].*curl' && block_command "REMOTE_CODE_EXEC" "eval/exec curl subshell"
echo "$COMMAND_LOWER" | grep -qE '(curl|wget).*-o\s*/tmp/.*&&.*(ba)?sh\s*/tmp/' && block_command "REMOTE_CODE_EXEC" "download and execute"
# Bypass: download → chmod +x → execute directly (without explicit sh/bash)
echo "$COMMAND_LOWER" | grep -qE '(curl|wget).*-o\s*/tmp/.*&&\s*chmod.*(\+x|[0-7]*[1357][0-7]{2}).*&&\s*/tmp/' && block_command "REMOTE_CODE_EXEC" "download chmod exec"

# === Reverse Shell / Network Listeners ===
echo "$COMMAND" | grep -qiE 'nc\s+(-[a-zA-Z]*)*(l|e)\s' && block_command "REVERSE_SHELL" "netcat listener/exec"
echo "$COMMAND" | grep -qiE 'ncat\s.*-e\s' && block_command "REVERSE_SHELL" "ncat exec"
echo "$COMMAND" | grep -qiE 'socat\s' && block_command "REVERSE_SHELL" "socat"
echo "$COMMAND" | grep -qE '/dev/tcp/' && block_command "REVERSE_SHELL" "/dev/tcp"
echo "$COMMAND" | grep -qiE 'bash\s+-i\s+>&\s*/dev/tcp' && block_command "REVERSE_SHELL" "bash reverse shell"
echo "$COMMAND" | grep -qiE 'python.*socket\..*connect' && block_command "REVERSE_SHELL" "python socket connect"
echo "$COMMAND" | grep -qiE 'php\s+-r.*fsockopen' && block_command "REVERSE_SHELL" "php reverse shell"
echo "$COMMAND" | grep -qiE 'ruby.*TCPSocket' && block_command "REVERSE_SHELL" "ruby tcp socket"
echo "$COMMAND" | grep -qiE 'perl.*socket' && block_command "REVERSE_SHELL" "perl socket"

# === Credential / Secret Access ===
# /proc/self/environ and /proc/<pid>/environ expose all env vars including secrets
echo "$COMMAND" | grep -qiE '/proc/(self|[0-9]+)/environ' && block_command "CREDENTIAL_ACCESS" "/proc environ"
echo "$COMMAND" | grep -qiE 'cat\s.*/etc/(shadow|passwd|sudoers)' && block_command "CREDENTIAL_ACCESS" "system auth files"
echo "$COMMAND" | grep -qiE 'cat\s.*\.ssh/(id_|.*key|authorized_keys|config)' && block_command "CREDENTIAL_ACCESS" "SSH keys"
echo "$COMMAND" | grep -qiE 'cat\s.*\.aws/(credentials|config)' && block_command "CREDENTIAL_ACCESS" "AWS credentials"
echo "$COMMAND" | grep -qiE 'cat\s.*\.(env|npmrc|pypirc|netrc|docker/config\.json)' && block_command "CREDENTIAL_ACCESS" "secrets file"
echo "$COMMAND" | grep -qiE '(printenv|echo\s+\$|printf.*\$).*(KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|API_KEY|PRIVATE)' && block_command "CREDENTIAL_ACCESS" "environment secrets"
echo "$COMMAND" | grep -qiE 'env\s*\|\s*grep\s+-i\s*(key|secret|token|pass|cred)' && block_command "CREDENTIAL_ACCESS" "env grep secrets"
echo "$COMMAND" | grep -qiE '(cp|mv|cat|less|more|head|tail)\s.*\.ssh/' && block_command "CREDENTIAL_ACCESS" "SSH directory access"
echo "$COMMAND" | grep -qiE 'base64.*\.ssh/' && block_command "CREDENTIAL_ACCESS" "base64 encode SSH"
echo "$COMMAND" | grep -qiE '(cp|mv|cat)\s.*/etc/shadow' && block_command "CREDENTIAL_ACCESS" "shadow file"

# === Privilege Escalation ===
# Also catch sudo( without space (e.g. $(sudo cmd) where sudo is preceded by open paren)
echo "$COMMAND" | grep -qE '(^|[[:space:](])(sudo|doas|pkexec)[[:space:](]' && block_command "PRIVILEGE_ESCALATION" "sudo/doas/pkexec"
echo "$COMMAND" | grep -qE '(^|\s)su\s+(-|root)' && block_command "PRIVILEGE_ESCALATION" "su root"
echo "$COMMAND" | grep -qiE 'chmod\s+([0-7]*7[0-7]{2}|u\+s|g\+s|\+s)' && block_command "PRIVILEGE_ESCALATION" "dangerous chmod"
echo "$COMMAND" | grep -qiE 'chown\s+(root|0:)' && block_command "PRIVILEGE_ESCALATION" "chown root"
echo "$COMMAND" | grep -qiE 'setuid|setcap|capabilities' && block_command "PRIVILEGE_ESCALATION" "capability manipulation"

# === Cloud IAM / Infrastructure Destruction ===
echo "$COMMAND" | grep -qiE 'aws\s+(iam|sts|organizations)' && block_command "CLOUD_IAM" "AWS IAM/STS"
echo "$COMMAND" | grep -qiE 'aws\s+s3\s+(rb|rm)' && block_command "CLOUD_IAM" "AWS S3 delete"
echo "$COMMAND" | grep -qiE 'aws\s+ec2\s+terminate' && block_command "CLOUD_IAM" "AWS EC2 terminate"
echo "$COMMAND" | grep -qiE 'gcloud\s+(iam|compute\s+instances\s+delete)' && block_command "CLOUD_IAM" "GCloud destructive"
echo "$COMMAND" | grep -qiE 'az\s+(ad|group\s+delete)' && block_command "CLOUD_IAM" "Azure destructive"
echo "$COMMAND" | grep -qiE 'kubectl\s+delete\s+(namespace|node|cluster|pv)' && block_command "CLOUD_IAM" "kubectl delete critical"
echo "$COMMAND" | grep -qiE 'terraform\s+destroy' && block_command "CLOUD_IAM" "terraform destroy"
echo "$COMMAND" | grep -qiE 'helm\s+uninstall' && block_command "CLOUD_IAM" "helm uninstall"

# === Data Exfiltration ===
echo "$COMMAND" | grep -qiE '(scp|sftp)\s' && block_command "DATA_EXFIL" "scp/sftp"
echo "$COMMAND" | grep -qiE 'rsync\s.*\.(ssh|aws|gnupg|config)' && block_command "DATA_EXFIL" "rsync secrets"
echo "$COMMAND" | grep -qiE 'curl\s.*(-d\s*@|-F\s.*file=@|--data-binary\s*@/)' && block_command "DATA_EXFIL" "curl upload file"
echo "$COMMAND" | grep -qiE 'wget\s+--post-file' && block_command "DATA_EXFIL" "wget post file"
echo "$COMMAND" | grep -qiE 'curl\s.*-X\s*(PUT|POST).*@/' && block_command "DATA_EXFIL" "curl upload"

# === Process / System Manipulation ===
echo "$COMMAND" | grep -qiE '(^|\s)(shutdown|reboot|poweroff|halt|init\s+[06])\s*' && block_command "SYSTEM_MANIP" "system shutdown/reboot"
echo "$COMMAND" | grep -qiE 'systemctl\s+(stop|disable|mask|restart)\s' && block_command "SYSTEM_MANIP" "systemctl destructive"
echo "$COMMAND" | grep -qiE 'kill\s+-9\s+1\s*$' && block_command "SYSTEM_MANIP" "kill init"
echo "$COMMAND" | grep -qiE '(^|\s)killall\s' && block_command "SYSTEM_MANIP" "killall"
echo "$COMMAND" | grep -qiE 'service\s+\S+\s+(stop|restart)' && block_command "SYSTEM_MANIP" "service stop"

# === Container Escape ===
echo "$COMMAND" | grep -qiE '(^|\s)(nsenter|unshare)\s' && block_command "CONTAINER_ESCAPE" "nsenter/unshare"
echo "$COMMAND" | grep -qiE 'mount\s.*(proc|sysfs|devpts|/dev)' && block_command "CONTAINER_ESCAPE" "mount sensitive fs"
echo "$COMMAND" | grep -qiE '(^|\s)chroot\s' && block_command "CONTAINER_ESCAPE" "chroot"
echo "$COMMAND" | grep -qiE 'docker\s+(run|exec|cp|build|save|export)' && block_command "CONTAINER_ESCAPE" "docker command"
echo "$COMMAND" | grep -qiE 'docker\.sock' && block_command "CONTAINER_ESCAPE" "docker socket"
echo "$COMMAND" | grep -qiE 'crictl|ctr|nerdctl' && block_command "CONTAINER_ESCAPE" "container runtime"

# === Crypto Mining ===
echo "$COMMAND" | grep -qiE '(xmrig|minerd|cpuminer|ccminer|ethminer|stratum\+tcp)' && block_command "CRYPTO_MINING" "cryptocurrency miner"

# === Network Scanning ===
echo "$COMMAND" | grep -qiE '(^|\s)(nmap|masscan|zmap|nikto|sqlmap)\s' && block_command "NETWORK_SCAN" "network scanner"

# === Git force operations to protected branches ===
echo "$COMMAND" | grep -qiE 'git\s+push\s+.*(-f|--force)' && block_command "GIT_FORCE" "force push"
echo "$COMMAND" | grep -qiE 'git\s+push\s+.*\s+(origin\s+)?(main|master)\s*$' && block_command "GIT_FORCE" "push to protected branch"
echo "$COMMAND" | grep -qiE 'git\s+reset\s+--hard' && block_command "GIT_FORCE" "git reset --hard"
echo "$COMMAND" | grep -qiE 'git\s+clean\s+-[a-zA-Z]*f' && block_command "GIT_FORCE" "git clean -f"

# === Package installation from untrusted sources ===
# Block all custom index-url for pip (any non-official index is a supply-chain risk in agent context)
echo "$COMMAND" | grep -qiE 'pip\s+install\s+--index-url' && block_command "UNTRUSTED_PKG" "pip custom index-url"
echo "$COMMAND" | grep -qiE 'npm\s+install\s+--registry\s+http://' && block_command "UNTRUSTED_PKG" "npm from HTTP"

# === Covert Network Services / Recon ===
echo "$COMMAND" | grep -qiE 'python[23]?\s+-m\s+http\.server' && block_command "COVERT_NETWORK" "python http server"
echo "$COMMAND" | grep -qiE 'python[23]?\s+-m\s+SimpleHTTPServer' && block_command "COVERT_NETWORK" "python SimpleHTTPServer"
echo "$COMMAND" | grep -qiE '(^|\s)strace\s' && block_command "COVERT_NETWORK" "strace syscall tracer"
echo "$COMMAND" | grep -qiE '(^|\s)ltrace\s' && block_command "COVERT_NETWORK" "ltrace library tracer"

# === Git hook / config manipulation ===
echo "$COMMAND" | grep -qiE 'git\s+config\s+.*core\.hooksPath' && block_command "GIT_HOOK_TAMPER" "git config core.hooksPath"
echo "$COMMAND" | grep -qiE 'git\s+config\s+.*core\.fsmonitor' && block_command "GIT_HOOK_TAMPER" "git config core.fsmonitor"

# === History / log manipulation ===
echo "$COMMAND" | grep -qiE '(history\s+-c|>\s*~/\.bash_history|unset\s+HISTFILE)' && block_command "LOG_TAMPER" "history manipulation"

# ---------------------------------------------------------------------------
# All checks passed - command is allowed
# ---------------------------------------------------------------------------
exit 0
