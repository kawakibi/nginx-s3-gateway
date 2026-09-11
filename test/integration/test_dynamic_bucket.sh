#!/usr/bin/env bash
# Copyright 2026 F5, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This suite only writes to the disposable RustFS origin passed by the runner.
# Two non-default buckets deliberately share keys with different contents.
set -euo pipefail
server=$1
. "$(dirname "${BASH_SOURCE[0]}")/s3_client_lib.sh" "$2" "$3" "$4"
bucket_header=$5
mode=$6
scratch=$(mktemp -d)
trap 'rm -rf "${scratch}"' EXIT

fail() { >&2 echo "FAIL [dynamic bucket]: $*"; exit 2; }
equal() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
header() {
  awk -v name="$1" 'tolower($1) == tolower(name) ":" {$1=""; sub(/^ /, ""); sub(/\r$/, ""); print}' "${scratch}/headers"
}
request() {
  local bucket=$1 path=$2 expected=$3
  shift 3
  local code
  code=$(curl --noproxy '*' -sS --connect-timeout 5 --max-time 30 \
    -H "${bucket_header}: ${bucket}" -D "${scratch}/headers" \
    -o "${scratch}/body" -w '%{http_code}' "$@" "${server}${path}")
  [ "${code}" = "${expected}" ] || fail "${bucket} ${path}: expected HTTP ${expected}, got ${code}"
}
assertBody() { cmp -s "$1" "${scratch}/body" || fail "wrong body for $1"; }
assertContains() { grep -qF "$1" "${scratch}/body" || fail "body lacks $1"; }
assertLacks() { if grep -qF "$1" "${scratch}/body"; then fail "body unexpectedly contains $1"; fi; }

for suffix in a b; do
  # 4096 bytes with differing contents; ranges cross the 1k slice boundaries.
  awk -v value="${suffix}" 'BEGIN { for (i=0; i<4096; i++) printf "%s", value }' > "${scratch}/${suffix}.bin"
  printf '<html>index from bucket %s</html>\n' "${suffix}" > "${scratch}/${suffix}.html"
done

if [ "${mode}" = objects ]; then
  for suffix in a b; do
    bucket="dynamic-bucket-${suffix}"
    if ! origin_client s3api create-bucket --bucket "${bucket}" > /dev/null 2>&1; then
      origin_client s3api head-bucket --bucket "${bucket}" > /dev/null
    fi
    origin_client s3api put-object --bucket "${bucket}" --key private/video.mp4 \
      --body "${scratch}/${suffix}.bin" --content-type video/mp4 > /dev/null
    origin_client s3api put-object --bucket "${bucket}" --key internal/site/index.html \
      --body "${scratch}/${suffix}.html" --content-type text/html > /dev/null
    origin_client s3api put-object --bucket "${bucket}" --key site/index.html \
      --body "${scratch}/${suffix}.html" --content-type text/html > /dev/null
    for leaf in 1 2; do
      origin_client s3api put-object --bucket "${bucket}" \
        --key "internal/list/${suffix}${leaf}.txt" --body "${scratch}/${suffix}.html" > /dev/null
    done
  done
  origin_client s3api put-object --bucket dynamic-bucket-b --key only-b.txt \
    --body "${scratch}/b.html" > /dev/null

  for expected_cache in MISS HIT; do
    for suffix in a b; do
      request "dynamic-bucket-${suffix}" /private/video.mp4 200
      equal "$(header X-Cache-Status)" "${expected_cache}"
      equal "$(header X-Bucket)" "dynamic-bucket-${suffix}"
      equal "$(header Content-Disposition)" inline
      equal "$(header Content-Type)" video/mp4
      assertBody "${scratch}/${suffix}.bin"
    done
  done
  for suffix in a b; do
    request "dynamic-bucket-${suffix}" /private/video.mp4 200 --head
    equal "$(header Content-Length)" 4096
    equal "$(header X-Bucket)" "dynamic-bucket-${suffix}"
    equal "$(header Content-Disposition)" inline
  done
  for expected_cache in MISS HIT; do
    for suffix in a b; do
      request "dynamic-bucket-${suffix}" /private/video.mp4 206 --range 800-2400
      equal "$(header X-Cache-Status)" "${expected_cache}"
      equal "$(header Content-Range)" 'bytes 800-2400/4096'
      equal "$(header X-Bucket)" "dynamic-bucket-${suffix}"
      equal "$(header Content-Disposition)" inline
      dd if="${scratch}/${suffix}.bin" of="${scratch}/range" bs=1 skip=800 count=1601 2>/dev/null
      assertBody "${scratch}/range"
    done
  done
  # A cached miss in one bucket must not hide another bucket's object.
  request dynamic-bucket-a /only-b.txt 404
  request dynamic-bucket-a /only-b.txt 404
  request dynamic-bucket-b /only-b.txt 200
  assertBody "${scratch}/b.html"

  for suffix in a b; do
    request "dynamic-bucket-${suffix}" /site/index.html 200
    assertBody "${scratch}/${suffix}.html"
  done
  # These paths are warm. Header omissions must still fail before lookup,
  # including the regex location and sliced requests, with no static fallback.
  for path in /private/video.mp4 /site/index.html /health/index.html /soap/index.html /; do
    request '' "${path}" 500
    request '' "${path}" 500 --head
  done
  request '' /private/video.mp4 500 --range 800-2400
  # curl's semicolon form sends an actual empty header instead of omitting it.
  request '' /private/video.mp4 500 -H "${bucket_header};"
  request '' /site/index.html 500 -H "${bucket_header};"
  saved_bucket_header=${bucket_header}
  bucket_header=$(printf '%s' "${bucket_header}" | tr '[:upper:]' '[:lower:]')
  request dynamic-bucket-a /private/video.mp4 200
  bucket_header=${saved_bucket_header}
  assertBody "${scratch}/a.bin"
elif [ "${mode}" = listing ]; then
  for suffix in a b; do
    # The loopback probe must carry the bucket and re-enter the viewer URI,
    # not apply the /viewer -> /internal rewrite a second time.
    request "dynamic-bucket-${suffix}" /viewer/site/ 200
    assertBody "${scratch}/${suffix}.html"
    request "dynamic-bucket-${suffix}" /viewer/site/index.html 200
    assertBody "${scratch}/${suffix}.html"
    request "dynamic-bucket-${suffix}" /viewer/list/ 200
    assertContains "${suffix}1.txt"
    assertContains 'Next page'
    assertLacks "${suffix}2.txt"
    marker=$(sed -n 's/.*href="?marker=\([^"]*\)".*/\1/p' "${scratch}/body")
    case "${marker}" in
      "${suffix}1.txt"*) ;;
      *) fail "pagination marker is not directory-relative: ${marker}" ;;
    esac
    request "dynamic-bucket-${suffix}" "/viewer/list/?marker=${marker}" 200
    assertContains "${suffix}2.txt"
    assertLacks "${suffix}1.txt</a>"
    assertLacks 'Next page'
  done
  request '' /viewer/site/index.html 500
  request '' /viewer/site/ 500
elif [ "${mode}" = cors ]; then
  request '' /health 200
  for path in /private/video.mp4 /site/index.html; do
    request '' "${path}" 204 -X OPTIONS -H 'Origin: https://viewer.example' \
      -H 'Access-Control-Request-Method: GET' \
      -H "Access-Control-Request-Headers: ${bucket_header}"
    equal "$(header Access-Control-Allow-Origin)" 'https://viewer.example'
    case "$(header Access-Control-Allow-Headers)" in
      *"${bucket_header}"*) ;;
      *) fail 'preflight does not allow the configured bucket header' ;;
    esac
    request '' "${path}" 500 -H 'Origin: https://viewer.example'
    equal "$(header Access-Control-Allow-Origin)" 'https://viewer.example'
  done
else
  fail "unknown test mode: ${mode}"
fi

echo "PASS: dynamic bucket ${mode}, header=${bucket_header}"
