#!/usr/bin/env bash
# Downloads the GGUF weights referenced by MODEL_REPO/MODEL_FILE into MODEL_DIR.
# Runs as a one-shot systemd unit (model-fetch.service) on first deployment.
# It resumes an interrupted transfer, verifies the size and, when MODEL_SHA256
# is set, the checksum before renaming the .part file into place.
set -euo pipefail

: "${MODEL_REPO:?MODEL_REPO is required}"
: "${MODEL_FILE:?MODEL_FILE is required}"
: "${MODEL_DIR:=/models}"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"

dest="${MODEL_DIR}/${MODEL_FILE}"
part="${dest}.part"
url="${HF_ENDPOINT}/${MODEL_REPO}/resolve/main/${MODEL_FILE}"

if [ -f "${dest}" ]; then
  echo "already present: ${dest}"
  exit 0
fi

echo "repo     : ${MODEL_REPO}"
echo "file     : ${MODEL_FILE}"
echo "target   : ${dest}"
echo "endpoint : ${HF_ENDPOINT}"

curl_args=(-fL --retry 5 --retry-delay 5 --retry-connrefused -C - -o "${part}")
curl_help=$(curl --help all 2>/dev/null || true)
if grep -q -- '--retry-all-errors' <<<"${curl_help}"; then
  curl_args+=(--retry-all-errors)
elif grep -q -- '--retry-error' <<<"${curl_help}"; then
  curl_args+=(--retry-error)
fi

if [ -n "${HF_TOKEN:-}" ]; then
  curl_args+=(-H "Authorization: Bearer ${HF_TOKEN}")
fi

echo "downloading -> ${part}"
curl "${curl_args[@]}" "${url}?download=true"

expected=$(curl -fsIL "${url}?download=true" \
  | tr -d '\r' \
  | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }')
actual=$(stat -c '%s' "${part}")

if [ -n "${expected:-}" ] && [ "${expected}" != "${actual}" ]; then
  echo "size mismatch: server says ${expected}, got ${actual}" >&2
  exit 1
fi

if [ -n "${MODEL_SHA256:-}" ]; then
  echo "verifying sha256 ${MODEL_SHA256} ..."
  echo "${MODEL_SHA256}  ${part}" | sha256sum -c -
fi

mv "${part}" "${dest}"
echo "done: ${dest}"
