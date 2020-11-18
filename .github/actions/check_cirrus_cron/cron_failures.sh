#!/bin/bash

set -eo pipefail

# Intended to be executed from a github action workflow step.
# Outputs the Cirrus cron names and IDs of any failed builds

err() {
    # Ref: https://docs.github.com/en/free-pro-team@latest/actions/reference/workflow-commands-for-github-actions
    echo "::error file=${BASH_SOURCE[0]},line=${BASH_LINENO[0]}::${1:-No error message given}"
    exit 1
}

if [[ -z "$GITHUB_REPOSITORY" ]]; then
    err "Expecting \$GITHUB_REPOSITORY value to not be empty"
elif [[ ! -w "$GITHUB_ENV" ]]; then
    err "Expecting \$GITHUB_ENV ($GITHUB_ENV) to be path to writable file"
fi

mkdir -p artifacts
cat > ./artifacts/query_raw.json << "EOF"
{"query":"
  query CronNameStatus($owner: String!, $repo: String!) {
    githubRepository(owner: $owner, name: $repo) {
      cronSettings {
        name
        lastInvocationBuild {
          id
          status
        }
      }
    }
  }
",
"variables":"{
  \"owner\": \"@@OWNER@@\",
  \"repo\": \"@@REPO@@\"
}"}
EOF
# Makes for easier copy/pasting query to/from
# https://cirrus-ci.com/explorer
owner=$(cut -d '/' -f 1 <<<"$GITHUB_REPOSITORY")
repo=$(cut -d '/' -f 2 <<<"$GITHUB_REPOSITORY")
sed -i -r -e "s/@@OWNER@@/$owner/g" -e "s/@@REPO@@/$repo/g" ./artifacts/query_raw.json

echo "::group::Posting GraphQL Query"
# Easier to debug in error-reply when query is compacted
tr -d '\n' < ./artifacts/query_raw.json | tr -s ' ' | tee ./artifacts/query.json | \
    jq --indent 4 --color-output .

if grep -q '@@' ./artifacts/query.json; then
    err "Found unreplaced substitution token in raw query JSON"
fi
curl \
  --request POST \
  --silent \
  --location \
  --header 'content-type: application/json' \
  --url 'https://api.cirrus-ci.com/graphql' \
  --data @./artifacts/query.json \
  --output ./artifacts/reply.json
echo "::endgroup::"

echo "::group::Received GraphQL Reply"
jq --indent 4 --color-output . <./artifacts/reply.json || \
    cat ./artifacts/reply.json
echo "::endgroup::"

# Desireable to catch non-JSON encoded errors in reply.
if grep -qi 'error' ./artifacts/reply.json; then
    err "Found the word 'error' in reply"
fi

# e.x. reply.json
# {
#   "data": {
#     "githubRepository": {
#       "cronSettings": [
#         {
#           "name": "Keepalive_v2.0",
#           "lastInvocationBuild": {
#             "id": "5776050544181248",
#             "status": "EXECUTING"
#           }
#         },
#         {
#           "name": "Keepalive_v1.9",
#           "lastInvocationBuild": {
#             "id": "5962921081569280",
#             "status": "COMPLETED"
#           }
#         },
#         {
#           "name": "Keepalive_v2.0.5-rhel",
#           "lastInvocationBuild": {
#             "id": "5003065549914112",
#             "status": "FAILED"
#           }
#         }
#       ]
#     }
#   }
# }
_filt='.data.githubRepository.cronSettings | map(select(.lastInvocationBuild.status=="FAILED") | { name:.name, id:.lastInvocationBuild.id} | join(" ")) | join("\n")'
jq --raw-output "$_filt" ./artifacts/reply.json > ./artifacts/name_id.csv

echo "<Cron Name> <Failed Build ID>"
cat ./artifacts/name_id.csv

# Don't rely on a newline present for zero/one output line, always count words
records=$(wc --words ./artifacts/name_id.csv | cut -d ' ' -f 1)
# Always two words per record
failures=$((records/2))
echo "::set-output name=failures::$failures"
echo "Total failed Cirrus-CI cron builds: $failures"
