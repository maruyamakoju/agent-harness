# =============================================================================
# 24/7 Autonomous Coding Agent - Docker Container (Layer 1)
# Base: Ubuntu 24.04 | User: agent (unprivileged) | GPU passthrough ready
# =============================================================================
FROM ubuntu:24.04 AS base

LABEL maintainer="agent-system" \
      description="24/7 Autonomous Coding Agent with Claude Code CLI"

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo

# -----------------------------------------------------------------------------
# System packages (rarely changes → cached layer)
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        git-lfs \
        jq \
        curl \
        wget \
        bc \
        ca-certificates \
        gnupg \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        build-essential \
        locales \
        tzdata \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# -----------------------------------------------------------------------------
# Node.js 22.x (LTS) - separate layer for caching
# -----------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm config set fund false \
    && npm config set update-notifier false \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# GitHub CLI (gh)
# -----------------------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Claude Code CLI (installed globally via npm)
# -----------------------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# -----------------------------------------------------------------------------
# Security: remove sudo, remove unnecessary setuid binaries
# -----------------------------------------------------------------------------
RUN apt-get purge -y sudo 2>/dev/null || true \
    && find / -perm /4000 -type f -exec chmod u-s {} \; 2>/dev/null || true \
    && find / -perm /2000 -type f -exec chmod g-s {} \; 2>/dev/null || true

# -----------------------------------------------------------------------------
# Unprivileged agent user
# -----------------------------------------------------------------------------
RUN groupadd -g 1000 agent \
    && useradd -m -u 1000 -g agent -s /bin/bash agent

# Create workspace directories owned by agent
RUN mkdir -p /harness/jobs/pending \
             /harness/jobs/running \
             /harness/jobs/done \
             /harness/jobs/failed \
             /harness/logs \
             /harness/scripts \
             /harness/hooks \
             /workspaces \
    && chown -R agent:agent /harness /workspaces

# -----------------------------------------------------------------------------
# SSH config for GitHub
# -----------------------------------------------------------------------------
RUN mkdir -p /home/agent/.ssh \
    && ssh-keyscan github.com gitlab.com bitbucket.org >> /home/agent/.ssh/known_hosts 2>/dev/null \
    && chown -R agent:agent /home/agent/.ssh \
    && chmod 700 /home/agent/.ssh \
    && chmod 644 /home/agent/.ssh/known_hosts

# -----------------------------------------------------------------------------
# Git global config for agent
# -----------------------------------------------------------------------------
RUN git config --system user.name "Autonomous Agent" \
    && git config --system user.email "agent@autonomous-coding-agent.local" \
    && git config --system init.defaultBranch main \
    && git config --system core.autocrlf input

# -----------------------------------------------------------------------------
# Copy harness scripts & hooks (changes frequently → late layer)
# -----------------------------------------------------------------------------
COPY --chown=agent:agent scripts/ /harness/scripts/
COPY --chown=agent:agent hooks/  /harness/hooks/
COPY --chown=agent:agent CLAUDE.md /harness/CLAUDE.md
COPY --chown=agent:agent .claude/ /home/agent/.claude/

RUN chmod +x /harness/scripts/*.sh /harness/hooks/*.sh

# -----------------------------------------------------------------------------
# Health check: heartbeat file must be updated within last 5 minutes
# -----------------------------------------------------------------------------
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
    CMD test -f /harness/logs/heartbeat.json \
        && test $(( $(date +%s) - $(date -r /harness/logs/heartbeat.json +%s) )) -lt 300

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------
USER agent
WORKDIR /harness
ENV HOME=/home/agent
ENV PATH="/harness/scripts:${PATH}"
ENV NODE_ENV=production

ENTRYPOINT ["/harness/scripts/agent-loop.sh"]
