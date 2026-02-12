#!/usr/bin/env bash
# Polls the current branch's PR status and updates the Gitpod environment name.
# When no PR exists, the name is left untouched (preserves the default AI-generated name).
# When a PR is merged/closed, the name is cleared back to default.
#
# Intended to run as a long-lived background process from dotfiles.
# Dependencies: curl, git, jq
# Auth: /usr/local/gitpod/secrets/token for Gitpod API, GH_TOKEN for GitHub API.

set -euo pipefail

POLL_INTERVAL="${PR_STATUS_POLL_INTERVAL:-30}"
GITPOD_API_HOST="${GITPOD_HOST:-https://app.gitpod.io}"
GITPOD_TOKEN_FILE="/usr/local/gitpod/secrets/token"
MAX_NAME_LEN=80

# GraphQL query: fetches PR status, review decision, and CI rollup in one call
read -r -d '' GQL_QUERY << 'EOF' || true
query($owner:String!,$repo:String!,$branch:String!) {
  repository(owner:$owner,name:$repo) {
    pullRequests(headRefName:$branch,first:1,orderBy:{field:UPDATED_AT,direction:DESC}) {
      nodes {
        number title state isDraft reviewDecision
        commits(last:1) {
          nodes { commit { statusCheckRollup { state } } }
        }
      }
    }
  }
}
EOF

GQL_QUERY_ONELINE=$(echo "$GQL_QUERY" | tr '\n' ' ' | sed 's/  */ /g')

get_env_id() {
    gitpod environment get -f id 2>/dev/null | tr -d '[:space:]'
}

get_repo_owner_and_name() {
    local url
    url=$(git remote get-url origin 2>/dev/null)
    echo "$url" | sed -E 's#.*github\.com[:/]##; s/\.git$//'
}

# Truncate title at a word boundary, append ellipsis if needed
truncate_title() {
    local title="$1" max="$2"
    if [ ${#title} -le "$max" ]; then
        echo "$title"
        return
    fi
    # Cut at max-1 to leave room for ellipsis char, then trim to last space
    local cut="${title:0:$((max - 1))}"
    # Find last space to break at word boundary
    if [[ "$cut" == *" "* ]]; then
        cut="${cut% *}"
    fi
    echo "${cut}…"
}

update_env_name() {
    local name="$1" env_id="$2" token
    token=$(cat "$GITPOD_TOKEN_FILE")

    # Escape double quotes in the name for JSON safety
    name=$(echo "$name" | sed 's/"/\\"/g')

    curl -sf -X POST "${GITPOD_API_HOST}/api/gitpod.v1.EnvironmentService/UpdateEnvironment" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"environmentId\": \"${env_id}\", \"metadata\": {\"name\": \"${name}\"}}" \
        >/dev/null 2>&1
}

query_pr() {
    local owner="$1" repo="$2" branch="$3"

    local payload
    payload=$(jq -nc \
        --arg q "$GQL_QUERY_ONELINE" \
        --arg owner "$owner" \
        --arg repo "$repo" \
        --arg branch "$branch" \
        '{query: $q, variables: {owner: $owner, repo: $repo, branch: $branch}}')

    curl -sf -X POST "https://api.github.com/graphql" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
}

compute_status_label() {
    local branch="$1" owner="$2" repo="$3"

    local response
    response=$(query_pr "$owner" "$repo" "$branch") || true

    if [ -z "$response" ]; then
        echo "__SKIP__"
        return
    fi

    local node_count
    node_count=$(echo "$response" | jq '.data.repository.pullRequests.nodes | length')

    if [ "$node_count" = "0" ]; then
        echo "__SKIP__"
        return
    fi

    local pr state title is_draft review_decision ci_state
    pr=$(echo "$response" | jq '.data.repository.pullRequests.nodes[0]')
    state=$(echo "$pr" | jq -r '.state')
    title=$(echo "$pr" | jq -r '.title')
    is_draft=$(echo "$pr" | jq -r '.isDraft')
    review_decision=$(echo "$pr" | jq -r '.reviewDecision // empty')
    ci_state=$(echo "$pr" | jq -r '.commits.nodes[0].commit.statusCheckRollup.state // empty')

    # Merged/closed — clear back to default
    if [ "$state" = "MERGED" ] || [ "$state" = "CLOSED" ]; then
        echo ""
        return
    fi

    local tag
    if [ "$is_draft" = "true" ]; then
        if [ "$ci_state" = "FAILURE" ] || [ "$ci_state" = "ERROR" ]; then
            tag="📝❌"
        elif [ "$ci_state" = "PENDING" ]; then
            tag="📝⏳"
        else
            tag="📝"
        fi
    elif [ "$ci_state" = "FAILURE" ] || [ "$ci_state" = "ERROR" ]; then
        tag="❌"
    elif [ "$review_decision" = "APPROVED" ]; then
        tag="✅"
    elif [ "$review_decision" = "CHANGES_REQUESTED" ]; then
        tag="🔄"
    elif [ "$review_decision" = "REVIEW_REQUIRED" ]; then
        if [ "$ci_state" = "PENDING" ]; then
            tag="⏳"
        else
            tag="👀"
        fi
    else
        if [ "$ci_state" = "PENDING" ]; then
            tag="⏳"
        else
            tag="🟢"
        fi
    fi

    local prefix="${tag} "
    local title_budget=$((MAX_NAME_LEN - ${#prefix}))
    local truncated
    truncated=$(truncate_title "$title" "$title_budget")

    echo "${prefix}${truncated}"
}

main() {
    if [ -z "${GH_TOKEN:-}" ]; then
        echo "error: GH_TOKEN is not set" >&2
        exit 1
    fi

    local env_id nwo owner repo last_label="__INIT__"

    env_id=$(get_env_id)
    if [ -z "$env_id" ]; then
        echo "error: could not determine environment ID" >&2
        exit 1
    fi

    nwo=$(get_repo_owner_and_name)
    owner="${nwo%%/*}"
    repo="${nwo##*/}"

    if [ -z "$owner" ] || [ -z "$repo" ]; then
        echo "error: could not determine repo owner/name from git remote" >&2
        exit 1
    fi

    echo "pr-status-env-name: polling every ${POLL_INTERVAL}s (env=${env_id} repo=${owner}/${repo})"

    while true; do
        local branch
        branch=$(git branch --show-current 2>/dev/null || echo "")
        if [ -z "$branch" ]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        local label
        label=$(compute_status_label "$branch" "$owner" "$repo")

        if [ "$label" = "__SKIP__" ]; then
            if [ "$last_label" != "__SKIP__" ] && [ "$last_label" != "__INIT__" ]; then
                update_env_name "" "$env_id" && echo "$(date +%H:%M:%S) cleared (no PR)"
            fi
            last_label="__SKIP__"
        elif [ "$label" != "$last_label" ]; then
            if update_env_name "$label" "$env_id"; then
                if [ -z "$label" ]; then
                    echo "$(date +%H:%M:%S) cleared (merged/closed)"
                else
                    echo "$(date +%H:%M:%S) updated: ${label}"
                fi
                last_label="$label"
            else
                echo "$(date +%H:%M:%S) failed to update name" >&2
            fi
        fi

        sleep "$POLL_INTERVAL"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
