#!/bin/bash
set -e

# ─── Colors & Styles ────────────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[38;5;203m"
GREEN="\033[38;5;83m"
YELLOW="\033[38;5;220m"
BLUE="\033[38;5;75m"
CYAN="\033[38;5;117m"
MAGENTA="\033[38;5;177m"
GRAY="\033[38;5;245m"

BG_BLUE="\033[44m"
BG_GREEN="\033[42m"
BG_RED="\033[41m"

# ─── Log Directory ───────────────────────────────────────────────────────────
LOG_DIR="./deploy-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# ─── Helpers ─────────────────────────────────────────────────────────────────
print_banner() {
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${BLUE}║   ${CYAN}AWS Resource Change Alerts — Deployment${BLUE}          ║${RESET}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

print_step() {
  local step="$1"
  local title="$2"
  echo ""
  echo -e "${BOLD}${MAGENTA}┌─ Step ${step} ─────────────────────────────────────────────${RESET}"
  echo -e "${BOLD}${MAGENTA}│  ${YELLOW}${title}${RESET}"
  echo -e "${BOLD}${MAGENTA}└────────────────────────────────────────────────────────${RESET}"
}

print_info() {
  echo -e "  ${CYAN}ℹ  $1${RESET}"
}

print_success() {
  echo -e "  ${GREEN}✔  $1${RESET}"
}

print_error() {
  echo -e "  ${RED}✘  $1${RESET}"
}

print_warn() {
  echo -e "  ${YELLOW}⚠  $1${RESET}"
}

print_skip() {
  echo -e "  ${GRAY}↷  $1${RESET}"
}

# Returns the CloudFormation stack status, or "DOES_NOT_EXIST" if the stack is absent.
get_stack_status() {
  local stack_name="$1" region="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query 'Stacks[0].StackStatus' \
    --output text \
    $AWS_OPTS 2>/dev/null || echo "DOES_NOT_EXIST"
}

# Polls until the stack leaves any *_IN_PROGRESS state. Returns the final stable status.
# Prints a live spinner while waiting. Times out after ~5 minutes.
wait_for_stable() {
  local stack_name="$1" region="$2"
  local status attempts=0 max=60
  tput civis 2>/dev/null || true
  while true; do
    status=$(get_stack_status "$stack_name" "$region")
    [[ "$status" != *"IN_PROGRESS"* ]] && { tput cnorm 2>/dev/null || true; echo "$status"; return; }
    attempts=$((attempts + 1))
    [ "$attempts" -ge "$max" ] && { tput cnorm 2>/dev/null || true; echo "TIMEOUT"; return; }
    printf "\r  ${YELLOW}⏳  Waiting for %s to settle... (%s)${RESET}  " "$region" "$status"
    sleep 5
  done
}

# Resolves any pre-existing stack state so a fresh deploy can proceed.
# Exit codes:
#   0 = ready to deploy
#   1 = already deployed (skip)
#   2 = unrecoverable — needs manual intervention
prepare_region_stack() {
  local stack_name="$1" region="$2"
  local status
  status=$(get_stack_status "$stack_name" "$region")

  # ── Wait out any in-progress operation first ──────────────────────────────
  if [[ "$status" == *"IN_PROGRESS"* ]]; then
    print_warn "$region: stack is ${status} — waiting to settle (up to 5 min)..."
    printf "\n"
    status=$(wait_for_stable "$stack_name" "$region")
    printf "\r%-70s\r" " "   # clear wait line
    if [ "$status" = "TIMEOUT" ]; then
      print_error "$region: timed out waiting for stack to settle — skipping"
      return 2
    fi
    print_info "$region: settled at ${status}"
  fi

  # ── Handle the stable state ───────────────────────────────────────────────
  case "$status" in

    DOES_NOT_EXIST)
      # Fresh region — deploy normally
      return 0
      ;;

    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE)
      # Stack is healthy — deploy normally (SAM handles no-change via --no-fail-on-empty-changeset)
      return 0
      ;;

    CREATE_FAILED|ROLLBACK_COMPLETE|REVIEW_IN_PROGRESS)
      # Leftover from a failed/interrupted previous attempt.
      # These block a fresh CREATE — the stack must be deleted manually first.
      print_warn  "$region: leftover stack found in state '${status}'"
      print_error "$region: cannot deploy until this stack is removed. Run:"
      echo -e "    ${GRAY}aws cloudformation delete-stack \\
      --stack-name ${stack_name} \\
      --region ${region} \\
      --profile ${PROFILE}${RESET}"
      echo -e "    ${GRAY}# Then wait for deletion to complete, and re-run this script.${RESET}"
      return 2
      ;;

    ROLLBACK_FAILED|DELETE_FAILED|UPDATE_ROLLBACK_FAILED)
      # CloudFormation is stuck — only a human can fix these.
      print_error "$region: stack is in unrecoverable state (${status})"
      print_error "  Manual fix required:"
      print_error "  aws cloudformation delete-stack --stack-name ${stack_name} --region ${region} --profile ${PROFILE}"
      return 2
      ;;

    *)
      # Unexpected state (e.g. IMPORT_COMPLETE) — warn and try anyway
      print_warn "$region: unexpected stack state '${status}' — attempting deploy"
      return 0
      ;;
  esac
}

# Spinner that runs while a background process is alive
# Usage: spinner $PID "label"
spinner() {
  local pid="$1"
  local label="$2"
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  tput civis 2>/dev/null || true   # hide cursor
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}${frames[$i]}${RESET}  ${DIM}%s${RESET}  " "$label"
    i=$(( (i+1) % ${#frames[@]} ))
    sleep 0.1
  done
  printf "\r%-60s\r" " "   # clear spinner line
  tput cnorm 2>/dev/null || true   # restore cursor
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
PROFILE=""
ACCOUNT_ALIAS=""
SENDER_EMAIL=""
EMAIL_ADDRESS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)        PROFILE="$2";       shift 2 ;;
    --account-alias)  ACCOUNT_ALIAS="$2"; shift 2 ;;
    --sender-email)   SENDER_EMAIL="$2";  shift 2 ;;
    --email)          EMAIL_ADDRESS="$2"; shift 2 ;;
    *)
      echo -e "${RED}Unknown option: $1${RESET}"
      echo "Usage: $0 --profile PROFILE --account-alias ALIAS --sender-email SENDER --email RECIPIENT"
      exit 1
      ;;
  esac
done

if [ -z "$PROFILE" ]; then
  print_error "--profile is required"
  echo "Usage: $0 --profile PROFILE --account-alias ALIAS --sender-email SENDER --email RECIPIENT"
  exit 1
fi
if [ -z "$ACCOUNT_ALIAS" ]; then
  print_error "--account-alias is required"
  echo "Usage: $0 --profile PROFILE --account-alias ALIAS --sender-email SENDER --email RECIPIENT"
  exit 1
fi
if [ -z "$SENDER_EMAIL" ]; then
  print_error "--sender-email is required  (must be verified in AWS SES)"
  echo "Usage: $0 --profile PROFILE --account-alias ALIAS --sender-email SENDER --email RECIPIENT"
  exit 1
fi
if [ -z "$EMAIL_ADDRESS" ]; then
  print_error "--email (recipient) is required"
  echo "Usage: $0 --profile PROFILE --account-alias ALIAS --sender-email SENDER --email RECIPIENT"
  exit 1
fi

AWS_OPTS="--profile $PROFILE"
REGIONS=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "ap-south-1" "ap-northeast-3" "ap-northeast-2" "ap-southeast-1" "ap-southeast-2" "ap-northeast-1")
TOTAL_REGIONS=${#REGIONS[@]}

# Track results for summary
declare -a REGION_STATUS
declare -a REGION_DURATION

# ─── Banner ───────────────────────────────────────────────────────────────────
print_banner
echo -e "  ${GRAY}Profile      :${RESET} ${BOLD}${PROFILE}${RESET}"
echo -e "  ${GRAY}Account Alias:${RESET} ${BOLD}${ACCOUNT_ALIAS}${RESET}"
echo -e "  ${GRAY}Sender       :${RESET} ${BOLD}${SENDER_EMAIL}${RESET}"
echo -e "  ${GRAY}Recipient    :${RESET} ${BOLD}${EMAIL_ADDRESS}${RESET}"
echo -e "  ${GRAY}Regions      :${RESET} ${BOLD}${TOTAL_REGIONS} regions${RESET}"
echo -e "  ${GRAY}Logs         :${RESET} ${DIM}${LOG_DIR}/${RESET}"

# ─── Step 1: Primary Stack ────────────────────────────────────────────────────
print_step "1/5" "Deploy primary stack  →  us-east-1"

LOG_FILE="${LOG_DIR}/primary-us-east-1.log"
sam deploy \
  --stack-name resource-change-alerts \
  --template-file template.yaml \
  --parameter-overrides \
      AccountAlias="$ACCOUNT_ALIAS" \
      SenderEmail="$SENDER_EMAIL" \
      RecipientEmail="$EMAIL_ADDRESS" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --resolve-s3 \
  --region us-east-1 \
  $AWS_OPTS > "$LOG_FILE" 2>&1 &

SAM_PID=$!
spinner $SAM_PID "Deploying primary stack to us-east-1"
wait $SAM_PID
print_success "Primary stack deployed  ${GRAY}(log: ${LOG_FILE})${RESET}"

# ─── Step 2: Get Central Event Bus ARN ───────────────────────────────────────
print_step "2/5" "Fetching Central Event Bus ARN"

CENTRAL_BUS_ARN=$(aws cloudformation describe-stacks \
  --stack-name resource-change-alerts \
  --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`CentralEventBusArn`].OutputValue' \
  --output text \
  $AWS_OPTS)

print_success "Central Event Bus ARN fetched"
echo -e "  ${GRAY}ARN:${RESET} ${DIM}${CENTRAL_BUS_ARN}${RESET}"

# ─── Step 3: Regional Stacks ──────────────────────────────────────────────────
print_step "3/5" "Deploy regional stacks  →  ${TOTAL_REGIONS} regions"
echo ""

idx=0
for REGION in "${REGIONS[@]}"; do
  idx=$((idx + 1))
  LOG_FILE="${LOG_DIR}/regional-${REGION}.log"

  # Progress indicator
  PERCENT=$(( idx * 100 / TOTAL_REGIONS ))
  FILLED=$(( idx * 20 / TOTAL_REGIONS ))
  BAR=""
  for ((f=0; f<FILLED; f++));   do BAR+="█"; done
  for ((f=FILLED; f<20; f++)); do BAR+="░"; done

  printf "  ${GRAY}[${idx}/${TOTAL_REGIONS}]${RESET} ${CYAN}%s${RESET}\n" "$REGION"
  printf "  ${BLUE}${BAR}${RESET} ${DIM}${PERCENT}%%${RESET}\n"

  # ── Resolve any pre-existing stack state ─────────────────────────────────
  PREP_RC=0
  prepare_region_stack "resource-change-alerts-regional" "$REGION" || PREP_RC=$?

  if [ "$PREP_RC" -eq 2 ]; then
    REGION_STATUS[$idx]="!"
    REGION_DURATION[$idx]="manual fix"
    echo ""
    continue
  fi

  START_TS=$(date +%s)

  sam deploy \
    --stack-name resource-change-alerts-regional \
    --template-file regional-rules.yaml \
    --parameter-overrides CentralEventBusArn=$CENTRAL_BUS_ARN \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset \
    --region "$REGION" \
    $AWS_OPTS > "$LOG_FILE" 2>&1 &

  SAM_PID=$!
  spinner $SAM_PID "  Deploying $REGION"

  END_TS=$(date +%s)
  DURATION=$(( END_TS - START_TS ))

  if wait $SAM_PID; then
    REGION_STATUS[$idx]="✔"
    REGION_DURATION[$idx]="${DURATION}s"
    print_success "${REGION}  ${GRAY}(${DURATION}s)${RESET}"
  else
    REGION_STATUS[$idx]="✘"
    REGION_DURATION[$idx]="${DURATION}s"
    print_error "${REGION} failed  ${GRAY}— see ${LOG_FILE}${RESET}"
    # Don't exit; continue so we get a full summary
  fi
  echo ""
done

# ─── Step 4: SES Verification Reminder ──────────────────────────────────────
print_step "4/4" "SES setup reminder"

print_success "Lambda function deployed and wired to EventBridge"
print_warn  "Ensure your sender email is verified in SES before alerts will send:"
echo -e "  ${GRAY}aws ses verify-email-identity --email-address ${SENDER_EMAIL} --region us-east-1 --profile ${PROFILE}${RESET}"
print_info  "If your SES account is in sandbox mode, the recipient must also be verified:"
echo -e "  ${GRAY}aws ses verify-email-identity --email-address ${EMAIL_ADDRESS} --region us-east-1 --profile ${PROFILE}${RESET}"

# ─── Summary Table ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║              Deployment Summary                      ║${RESET}"
echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════╣${RESET}"
printf  "${BOLD}${BLUE}║${RESET}  %-28s %-10s %-10s ${BOLD}${BLUE}║${RESET}\n" "Region" "Status" "Duration"
echo -e "${BOLD}${BLUE}║${RESET}  ${GRAY}──────────────────────────────────────────────────${RESET}  ${BOLD}${BLUE}║${RESET}"

# Primary stack row
printf "${BOLD}${BLUE}║${RESET}  %-28s ${GREEN}%-10s${RESET} %-10s ${BOLD}${BLUE}║${RESET}\n" "us-east-1 (primary)" "✔ OK" ""

idx=0
for REGION in "${REGIONS[@]}"; do
  idx=$((idx + 1))
  STATUS="${REGION_STATUS[$idx]}"
  DUR="${REGION_DURATION[$idx]}"
  if [ "$STATUS" = "✔" ]; then
    COLOR="$GREEN"
    LABEL="✔ OK"
  elif [ "$STATUS" = "↷" ]; then
    COLOR="$GRAY"
    LABEL="↷ skipped"
  elif [ "$STATUS" = "!" ]; then
    COLOR="$YELLOW"
    LABEL="! manual fix"
  else
    COLOR="$RED"
    LABEL="✘ FAILED"
  fi
  printf "${BOLD}${BLUE}║${RESET}  %-28s ${COLOR}%-10s${RESET} %-10s ${BOLD}${BLUE}║${RESET}\n" "$REGION" "$LABEL" "$DUR"
done

echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${BLUE}║${RESET}  ${GRAY}Profile      :${RESET} ${BOLD}${PROFILE}${RESET}"
echo -e "${BOLD}${BLUE}║${RESET}  ${GRAY}Account Alias:${RESET} ${BOLD}${ACCOUNT_ALIAS}${RESET}"
echo -e "${BOLD}${BLUE}║${RESET}  ${GRAY}Sender       :${RESET} ${DIM}${SENDER_EMAIL}${RESET}"
echo -e "${BOLD}${BLUE}║${RESET}  ${GRAY}Recipient    :${RESET} ${DIM}${EMAIL_ADDRESS}${RESET}"
echo -e "${BOLD}${BLUE}║${RESET}  ${GRAY}Logs         :${RESET} ${DIM}${LOG_DIR}/${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
