#!/usr/bin/env bash

# Default CLI options
BACKUP_DIR="$HOME/github_backups"
CONCURRENCY=8
BASE_DELAY=10       # Initial retry delay in seconds
MAX_DELAY=3000      # Max retry delay backoff cap (50 minutes)
MAX_RETRIES=10
ENABLE_NOTIFY=true
VERBOSITY=2        # 0 = Silent, 1 = Errors only, 2 = Normal info, 3 = Debug

# Parse command-line options
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--dir)
      BACKUP_DIR="$2"
      shift 2
      ;;
    -c|--concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    -b|--base-delay)
      BASE_DELAY="$2"
      shift 2
      ;;
    -m|--max-delay)
      MAX_DELAY="$2"
      shift 2
      ;;
    -r|--max-retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    --notify)
      ENABLE_NOTIFY="$2"
      shift 2
      ;;
    -v|--verbosity)
      VERBOSITY="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "  -d, --dir <path>          Backup directory (default: $HOME/github_backups)"
      echo "  -c, --concurrency <num>   Parallel jobs (default: 8)"
      echo "  -b, --base-delay <sec>    Initial retry delay in seconds (default: 10)"
      echo "  -m, --max-delay <sec>     Maximum retry backoff wait limit in seconds (default: 3000)"
      echo "  -r, --max-retries <num>   Max retries per repo (default: 10)"
      echo "  --notify <true|false>     Enable desktop notifications (default: true)"
      echo "  -v, --verbosity <0-3>     Verbosity level: 0=Quiet, 1=Errors, 2=Normal, 3=Debug (default: 2)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Bold ANSI colors
BOLD_GREEN='\033[1;32m'
BOLD_BLUE='\033[1;34m'
BOLD_YELLOW='\033[1;33m'
BOLD_CYAN='\033[1;36m'
BOLD_RED='\033[1;31m'
NC='\033[0m'

send_notification() {
  local urgency="$1"
  local title="$2"
  local message="$3"
  if [ "$ENABLE_NOTIFY" = true ] && command -v notify-send >/dev/null 2>&1; then
    notify-send -u "$urgency" "$title" "$message"
  fi
}

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR" || exit 1

[ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_BLUE}===> [INITIALIZING] Fetching repository list from GitHub...${NC}"
START_TIME=$(date +%s)

GITHUB_USER=$(gh api user --jq .login 2>/dev/null || gh api user -q .login 2>/dev/null || echo "")
GITHUB_USER=$(echo "$GITHUB_USER" | tr -d '"' | tr -d '\r' | xargs 2>/dev/null || echo "$GITHUB_USER")

REPOS=$(gh repo list --limit 1000 --json name -q '.[].name')
REPO_COUNT=$(echo "$REPOS" | grep -c '^')

if [ "$REPO_COUNT" -eq 0 ]; then
  [ "$VERBOSITY" -ge 1 ] && echo -e "${BOLD_RED}[ERROR] No repositories found or GitHub CLI authentication failed.${NC}"
  send_notification "critical" "GitHub Sync Error" "Failed to retrieve repository list."
  exit 1
fi

send_notification "low" "GitHub Sync Started" "Syncing $REPO_COUNT repositories with $CONCURRENCY parallel workers."
if [ -n "$GITHUB_USER" ]; then
  [ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_GREEN}===> [FOUND] $REPO_COUNT repositories detected for @${GITHUB_USER}.${NC}"
else
  [ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_GREEN}===> [FOUND] $REPO_COUNT repositories detected.${NC}"
fi
[ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_BLUE}===> [SYNC START] Processing with $CONCURRENCY parallel workers...${NC}\n"

# Progress counter for parallel jobs (atomic via flock)
PROGRESS_FILE=$(mktemp)
echo 0 > "$PROGRESS_FILE"
trap 'rm -f "$PROGRESS_FILE" "${PROGRESS_FILE}.lock"' EXIT

sync_repo() {
  REPO="$1"
  FOLDER="${REPO}.git"
  SINGLE_START=$(date +%s)
  RETRIES=0
  CURRENT_DELAY="$BASE_DELAY"

  # Atomically assign sequential index [1..REPO_COUNT] for this repo
  exec 200>"${PROGRESS_FILE}.lock"
  flock -x 200
  PROGRESS_IDX=$(cat "$PROGRESS_FILE")
  PROGRESS_IDX=$((PROGRESS_IDX + 1))
  echo "$PROGRESS_IDX" > "$PROGRESS_FILE"
  flock -u 200
  exec 200>&-

  while [ "$RETRIES" -le "$MAX_RETRIES" ]; do
    if [ -d "$FOLDER" ]; then
      [ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_YELLOW}[UPDATING ${PROGRESS_IDX}/${REPO_COUNT}]${NC} $REPO -> Fetching remote branches..."
      OUTPUT=$(git -C "$FOLDER" remote update --prune 2>&1)
      EXIT_CODE=$?
    else
      [ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_CYAN}[CLONING ${PROGRESS_IDX}/${REPO_COUNT}]${NC} $REPO -> Mirroring bare repo..."
      OUTPUT=$(gh repo clone "$REPO" "$FOLDER" -- --mirror 2>&1)
      EXIT_CODE=$?
    fi

    SINGLE_END=$(date +%s)
    DIFF=$((SINGLE_END - SINGLE_START))

    if [ $EXIT_CODE -eq 0 ]; then
      [ "$VERBOSITY" -ge 2 ] && echo -e "${BOLD_GREEN}[DONE ${PROGRESS_IDX}/${REPO_COUNT}]${NC} $REPO synced (${DIFF}s)."
      [ "$VERBOSITY" -ge 3 ] && echo -e "[DEBUG] Output for $REPO:\n$OUTPUT"
      return 0
    else
      RETRIES=$((RETRIES + 1))
      
      if [ "$RETRIES" -le "$MAX_RETRIES" ]; then
        if echo "$OUTPUT" | grep -iq -e "rate limit" -e "secondary rate" -e "403" -e "503"; then
          [ "$VERBOSITY" -ge 1 ] && echo -e "${BOLD_RED}[RATE LIMIT ${PROGRESS_IDX}/${REPO_COUNT}]${NC} $REPO hit API limits. Backing off for ${CURRENT_DELAY}s (Attempt $RETRIES/$MAX_RETRIES)..."
        else
          [ "$VERBOSITY" -ge 1 ] && echo -e "${BOLD_RED}[RETRY ${PROGRESS_IDX}/${REPO_COUNT}]${NC} $REPO failed. Backing off for ${CURRENT_DELAY}s (Attempt $RETRIES/$MAX_RETRIES)..."
        fi

        sleep "$CURRENT_DELAY"

        # Exponential backoff calculation: delay = delay * 2 capped at MAX_DELAY
        CURRENT_DELAY=$((CURRENT_DELAY * 2))
        if [ "$CURRENT_DELAY" -gt "$MAX_DELAY" ]; then
          CURRENT_DELAY="$MAX_DELAY"
        fi
      fi
    fi
  done

  [ "$VERBOSITY" -ge 1 ] && echo -e "${BOLD_RED}[FAILED ${PROGRESS_IDX}/${REPO_COUNT}]${NC} $REPO failed after $MAX_RETRIES retries:\n$OUTPUT"
  send_notification "critical" "GitHub Sync Failed" "Repository $REPO failed after $MAX_RETRIES retries."
  return 1
}

export -f sync_repo
export send_notification
export BOLD_GREEN BOLD_BLUE BOLD_YELLOW BOLD_CYAN BOLD_RED NC
export BASE_DELAY MAX_DELAY MAX_RETRIES ENABLE_NOTIFY VERBOSITY REPO_COUNT PROGRESS_FILE

# Stream parallel jobs via xargs
echo "$REPOS" | xargs -P "$CONCURRENCY" -I {} bash -c 'sync_repo "$@"' _ {}

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

if [ "$VERBOSITY" -ge 2 ]; then
  echo -e "\n${BOLD_GREEN}==========================================${NC}"
  echo -e "${BOLD_GREEN} Finished syncing $REPO_COUNT repositories${NC}"
  echo -e "${BOLD_GREEN} Total Execution Time: ${TOTAL_TIME}s${NC}"
  echo -e "${BOLD_GREEN}==========================================${NC}"
fi

send_notification "normal" "GitHub Sync Completed" "Processed $REPO_COUNT repos in ${TOTAL_TIME}s."
