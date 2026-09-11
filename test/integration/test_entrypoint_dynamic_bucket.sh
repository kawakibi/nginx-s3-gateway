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

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "$1"

baseline_extra_env=(
  -e AWS_ACCESS_KEY_ID=unit_test -e AWS_SECRET_ACCESS_KEY=unit_test
  -e AWS_SIGS_VERSION=4
)

assertValidationAccepts "dynamic mode unset"
for value in false FALSE no 0 ""; do
  assertValidationAccepts "dynamic mode disabled: '${value}'" \
    -e ALLOW_DYNAMIC_BUCKET_NAME="${value}"
done
for value in true TrUe YES 1; do
  assertValidationAccepts "dynamic path style: '${value}'" \
    -e S3_STYLE=path -e ALLOW_DYNAMIC_BUCKET_NAME="${value}"
done
for value in on enabled 'true ' $'true\n'; do
  assertValidationRejects "invalid dynamic boolean: '${value}'" \
    "ALLOW_DYNAMIC_BUCKET_NAME contains an invalid value" \
    -e S3_STYLE=path -e ALLOW_DYNAMIC_BUCKET_NAME="${value}"
done
for style in virtual virtual-v2 default invalid; do
  assertValidationRejects "dynamic bucket with ${style}" \
    "ALLOW_DYNAMIC_BUCKET_NAME requires S3_STYLE=path" \
    -e S3_STYLE="${style}" -e ALLOW_DYNAMIC_BUCKET_NAME=true
done
assertBannerContains "dynamic mode off by default" \
  "Dynamic Bucket Name Enabled: false"
assertBannerContains "default bucket header" \
  "Dynamic Bucket Name Source Header: X-Bucket-Name"
assertBannerContains "custom bucket header" \
  "Dynamic Bucket Name Source Header: X-Custom-Bucket-Name" \
  -e S3_STYLE=path -e ALLOW_DYNAMIC_BUCKET_NAME=true \
  -e HEADER_DYNAMIC_BUCKET_NAME=X-Custom-Bucket-Name

echo "PASS: dynamic bucket startup validation and defaults"
