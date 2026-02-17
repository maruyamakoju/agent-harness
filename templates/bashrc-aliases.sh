# =============================================================================
# Agent System Aliases
# Add to ~/.bashrc: source ~/agent-harness/templates/bashrc-aliases.sh
# =============================================================================

export HARNESS_DIR="${HARNESS_DIR:-$HOME/agent-harness}"

# Job management
alias job='$HARNESS_DIR/scripts/create-job.sh'
alias jobs-list='$HARNESS_DIR/scripts/list-jobs.sh'
alias jobs-pending='$HARNESS_DIR/scripts/list-jobs.sh pending'
alias jobs-running='$HARNESS_DIR/scripts/list-jobs.sh running'
alias jobs-failed='$HARNESS_DIR/scripts/list-jobs.sh failed'
alias jobs-done='$HARNESS_DIR/scripts/list-jobs.sh done'
alias job-cancel='$HARNESS_DIR/scripts/cancel-job.sh'
alias job-log='$HARNESS_DIR/scripts/view-job-log.sh'

# Monitoring
alias agent-status='$HARNESS_DIR/scripts/monitor.sh'
alias agent-watch='$HARNESS_DIR/scripts/monitor.sh watch'
alias agent-logs='docker compose -f $HARNESS_DIR/docker-compose.yml logs -f --tail 50'

# Container management
alias agent-restart='docker compose -f $HARNESS_DIR/docker-compose.yml restart'
alias agent-stop='docker compose -f $HARNESS_DIR/docker-compose.yml down --timeout 120'
alias agent-start='docker compose -f $HARNESS_DIR/docker-compose.yml up -d'
alias agent-shell='docker exec -it coding-agent bash'

# GPU
alias gpu='nvidia-smi'
alias gpu-watch='watch -n 1 nvidia-smi'
