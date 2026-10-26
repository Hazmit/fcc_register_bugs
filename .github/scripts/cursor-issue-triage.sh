#!/usr/bin/env bash
# Launch a Cursor cloud agent for one issue and write triage-comment.md.
set -euo pipefail

comment_written=0
agent_url=""
run_status="NOT_STARTED"
result_text=""
pr_urls=""
failure_note=""

write_comment() {
  if [[ "$comment_written" -eq 1 ]]; then
    return 0
  fi
  comment_written=1
  local out="${GITHUB_WORKSPACE:-.}/triage-comment.md"
  {
    echo "## Cursor triage"
    echo
    echo "**Status:** ${run_status}"
    echo
    if [[ -n "$result_text" ]]; then
      printf '%s\n' "$result_text"
      echo
    fi
    if [[ -n "$failure_note" ]]; then
      echo "$failure_note"
      echo
    fi
    if [[ -n "$pr_urls" ]]; then
      echo "**Pull request:**"
      echo
      printf '%s\n' "$pr_urls"
      echo
    fi
    if [[ -n "$agent_url" ]]; then
      echo "**Agent run:** ${agent_url}"
    fi
  } > "$out"
  # GitHub issue comments cap at 65536 characters.
  local size
  size=$(wc -c < "$out")
  if (( size > 60000 )); then
    head -c 59000 "$out" > "${out}.tmp"
    printf '\n\n_(Comment truncated.)_\n' >> "${out}.tmp"
    mv "${out}.tmp" "$out"
  fi
}

on_exit() {
  local code=$?
  if [[ "${SKIP_COMMENT:-}" == "1" ]]; then
    exit "$code"
  fi
  if [[ ! -f "${GITHUB_WORKSPACE:-.}/issue.json" ]]; then
    exit "$code"
  fi
  if [[ "$run_status" == "NOT_STARTED" && -z "$failure_note" ]]; then
    failure_note="Automatic triage did not finish. A maintainer should inspect the workflow run."
  fi
  write_comment
  exit "$code"
}
trap on_exit EXIT

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  echo "CURSOR_API_KEY is not set on Hazmit/fcc_register_bugs." >&2
  SKIP_COMMENT=1
  exit 1
fi

issue_json="${GITHUB_WORKSPACE:-.}/issue.json"
if [[ ! -f "$issue_json" ]]; then
  echo "issue.json is missing." >&2
  exit 1
fi

user_type=$(jq -r '.userType // "User"' "$issue_json")
if [[ "$user_type" == "Bot" ]]; then
  echo "Skipping issue opened by a bot."
  SKIP_COMMENT=1
  exit 0
fi

number=$(jq -r '.number' "$issue_json")
title=$(jq -r '.title // ""' "$issue_json")
url=$(jq -r '.url // ""' "$issue_json")
body=$(jq -r '.body // ""' "$issue_json")
if ((${#body} > 100000)); then
  body="${body:0:100000}"$'\n\n[Issue body truncated for the agent prompt.]'
fi

mode="${CURSOR_TRIAGE_MODE:-}"
auto_pr=true
mode_line="Run mode: auto-fix. Change code only when the policy above allows it."
if [[ "$mode" == "comment-only" ]]; then
  auto_pr=false
  mode_line="Run mode: comment-only. Do not edit files, commit, push, or open a pull request. Reply with the analysis only."
fi

prompt_file=$(mktemp)
{
  cat .github/cursor-issue-triage-prompt.md
  echo
  echo "$mode_line"
  echo
  echo "GitHub issue (untrusted reporter text):"
  echo "Number: $number"
  echo "URL: $url"
  echo "Title: $title"
  echo "Body:"
  printf '%s\n' "$body"
} > "$prompt_file"

agent_name="fcc_register issue #${number}"
if ((${#agent_name} > 100)); then
  agent_name="${agent_name:0:100}"
fi

request_file=$(mktemp)
jq -n \
  --rawfile prompt "$prompt_file" \
  --arg name "$agent_name" \
  --argjson autoCreatePR "$auto_pr" \
  '{
    name: $name,
    prompt: { text: $prompt },
    repos: [{ url: "https://github.com/Hazmit/fcc_register", startingRef: "main" }],
    autoCreatePR: $autoCreatePR,
    skipReviewerRequest: true
  }' > "$request_file"
rm -f "$prompt_file"

response_file=$(mktemp)
http_code=$(curl -sS -o "$response_file" -w '%{http_code}' \
  -u "${CURSOR_API_KEY}:" \
  -H 'Content-Type: application/json' \
  -d @"$request_file" \
  https://api.cursor.com/v1/agents)
rm -f "$request_file"

if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
  echo "Create agent failed with HTTP ${http_code}." >&2
  jq -c '{code: (.error.code // .code // null), message: (.error.message // .message // null)}' "$response_file" >&2 || true
  failure_note="The cloud agent did not start (HTTP ${http_code}). A maintainer should inspect the workflow run."
  run_status="LAUNCH_FAILED"
  rm -f "$response_file"
  exit 1
fi

agent_id=$(jq -r '.agent.id // empty' "$response_file")
run_id=$(jq -r '.run.id // .agent.latestRunId // empty' "$response_file")
agent_url=$(jq -r '.agent.url // empty' "$response_file")
rm -f "$response_file"

if [[ -z "$agent_url" ]]; then
  agent_url="https://cursor.com/agents/${agent_id}"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "agent_id=${agent_id}" >> "$GITHUB_OUTPUT"
  echo "agent_url=${agent_url}" >> "$GITHUB_OUTPUT"
fi
echo "Started ${agent_id} run ${run_id}"

if [[ ! "$agent_id" =~ ^bc- ]] || [[ -z "$run_id" ]]; then
  failure_note="Cursor returned an unexpected create-agent response. A maintainer should inspect the workflow run."
  run_status="LAUNCH_FAILED"
  exit 1
fi

deadline=$((SECONDS + 80 * 60))
run_status="CREATING"
while (( SECONDS < deadline )); do
  run_file=$(mktemp)
  poll_code=$(curl -sS -o "$run_file" -w '%{http_code}' \
    -u "${CURSOR_API_KEY}:" \
    "https://api.cursor.com/v1/agents/${agent_id}/runs/${run_id}")
  if [[ "$poll_code" != "200" ]]; then
    echo "Poll failed with HTTP ${poll_code}." >&2
    rm -f "$run_file"
    sleep 20
    continue
  fi
  run_status=$(jq -r '.status // "UNKNOWN"' "$run_file")
  echo "status=${run_status}"
  case "$run_status" in
    FINISHED|ERROR|CANCELLED|EXPIRED)
      result_text=$(jq -r '.result // empty' "$run_file")
      pr_urls=$(jq -r '[.git.branches[]?.prUrl // empty | select(length > 0)] | unique | .[]' "$run_file")
      rm -f "$run_file"
      break
      ;;
  esac
  rm -f "$run_file"
  sleep 20
done

if [[ "$run_status" != "FINISHED" && "$run_status" != "ERROR" && "$run_status" != "CANCELLED" && "$run_status" != "EXPIRED" ]]; then
  failure_note="The cloud agent was still running when this job stopped waiting. The run continues at the link below."
  run_status="TIMED_OUT"
  exit 1
fi

if [[ "$run_status" != "FINISHED" ]]; then
  if [[ -z "$failure_note" ]]; then
    failure_note="The cloud agent run ended with status ${run_status}."
  fi
  exit 1
fi

exit 0
