#!/bin/bash

# Copyright 2026 Iguazio
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Asserts that two images carry the same $SPARK_HOME/jars by content, not just
# by filename.

set -euo pipefail

IMAGE_A="${1:?usage: jar-parity.sh <image-a> <image-b>}"
IMAGE_B="${2:?usage: jar-parity.sh <image-a> <image-b>}"

checksums() {
  # LC_ALL=C: the two images may differ in locale, and collation order would
  # otherwise diff even when the contents match.
  docker run --rm --platform linux/amd64 \
    --entrypoint bash "$1" -c \
    'cd "$SPARK_HOME/jars" && LC_ALL=C sha256sum *.jar | LC_ALL=C sort'
}

echo "==> comparing \$SPARK_HOME/jars: $IMAGE_A vs $IMAGE_B"
a="$(checksums "$IMAGE_A")"
b="$(checksums "$IMAGE_B")"

count="$(wc -l <<<"$a" | tr -d '[:space:]')"
[[ "$count" -gt 0 ]] || { echo "FAIL: no JARs found in $IMAGE_A"; exit 1; }

if [[ "$a" != "$b" ]]; then
  echo "FAIL: JAR contents differ:"
  diff <(echo "$a") <(echo "$b") || true
  exit 1
fi

echo "==> $count JARs identical by SHA-256"
