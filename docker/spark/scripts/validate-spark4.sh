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
# Spark 4 counterpart of validate.sh. Local image checks that do not require
# a GPU.

set -euo pipefail

IMAGE="${1:?usage: validate-spark4.sh <image> [--cuda]}"
CUDA_MODE="${2:-}"

PINNED_CUDA_VERSION="12.8.1"
PINNED_CUDNN_VERSION="9.8.0.87-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR_MANIFEST="$SCRIPT_DIR/jars-4.2.0.txt"

EXPECTED_BASE_JARS=(
  hadoop-client-api-3.5.0.jar
  hadoop-client-runtime-3.5.0.jar
)

[[ -f "$JAR_MANIFEST" ]] || { echo "missing JAR manifest: $JAR_MANIFEST" >&2; exit 1; }
EXPECTED_CONNECTOR_JARS=()
while read -r line || [ -n "$line" ]; do
  url="${line%%#*}"
  url="$(echo "$url" | tr -d '[:space:]')"
  [ -z "$url" ] && continue
  EXPECTED_CONNECTOR_JARS+=("$(basename "$url")")
done < "$JAR_MANIFEST"
[[ ${#EXPECTED_CONNECTOR_JARS[@]} -gt 0 ]] || { echo "no connector JARs listed in $JAR_MANIFEST" >&2; exit 1; }

run() {
  docker run --rm --platform linux/amd64 --entrypoint bash "$IMAGE" -c "$1"
}

echo "==> [$IMAGE] linux/amd64 architecture"
arch="$(docker inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')"
[[ "$arch" == "linux/amd64" ]] || { echo "FAIL: unexpected architecture: '$arch'"; exit 1; }
uname_m="$(run 'uname -m')"
[[ "$uname_m" == "x86_64" ]] || { echo "FAIL: unexpected uname -m: '$uname_m'"; exit 1; }

echo "==> [$IMAGE] preserves the Spark entrypoint"
entrypoint="$(docker inspect "$IMAGE" --format '{{json .Config.Entrypoint}}')"
[[ "$entrypoint" == '["/opt/entrypoint.sh"]' ]] || { echo "FAIL: unexpected entrypoint: '$entrypoint'"; exit 1; }

echo "==> [$IMAGE] runs as the spark user"
whoami="$(run 'whoami')"
[[ "$whoami" == "spark" ]] || { echo "FAIL: expected spark user, got '$whoami'"; exit 1; }

echo "==> [$IMAGE] working spark-submit / Spark 4.2.0 / Scala 2.13"
spark_version="$(run '$SPARK_HOME/bin/spark-submit --version 2>&1')"
grep -q 'version 4.2.0' <<<"$spark_version" || { echo "FAIL: Spark is not version 4.2.0:"; echo "$spark_version"; exit 1; }
grep -q 'Scala version 2.13' <<<"$spark_version" || { echo "FAIL: Scala is not version 2.13:"; echo "$spark_version"; exit 1; }

echo "==> [$IMAGE] Temurin 25.0.4+7"
java_version="$(run 'java -version 2>&1')"
grep -Fq 'Temurin-25.0.4+7' <<<"$java_version" || { echo "FAIL: Java is not Temurin 25.0.4+7:"; echo "$java_version"; exit 1; }

echo "==> [$IMAGE] Hadoop 3.5.0"
for jar in "${EXPECTED_BASE_JARS[@]}"; do
  run "test -f \$SPARK_HOME/jars/$jar" || { echo "FAIL: missing jar $jar"; exit 1; }
done

echo "==> [$IMAGE] ${#EXPECTED_CONNECTOR_JARS[@]} connector JARs"
for jar in "${EXPECTED_CONNECTOR_JARS[@]}"; do
  run "test -f \$SPARK_HOME/jars/$jar" || { echo "FAIL: missing connector jar $jar"; exit 1; }
done

echo "==> [$IMAGE] no duplicate connector versions"
CONNECTOR_JAR_PREFIXES='^(hadoop-aws|hadoop-azure|hadoop-common|hadoop-gcp|aws-java-sdk-bundle|bundle|analyticsaccelerator-s3|wildfly-openssl|azure-storage|gcs-connector|jetty-util|jetty-util-ajax|spark-bigquery-with-dependencies(_[0-9]+\.[0-9]+)?)-'
duplicates="$(run 'ls "$SPARK_HOME/jars"' | grep -E "$CONNECTOR_JAR_PREFIXES" | sed -E 's/(_[0-9]+\.[0-9]+)?-[0-9][A-Za-z0-9._-]*\.jar$//' | sort | uniq -d)"
[[ -z "$duplicates" ]] || { echo "FAIL: duplicate connector artifacts:"; echo "$duplicates"; exit 1; }

echo "==> [$IMAGE] connector classes resolve"
for class in \
  org.apache.hadoop.fs.s3a.S3AFileSystem \
  org.apache.hadoop.fs.azurebfs.oauth2.WorkloadIdentityTokenProvider \
  org.apache.hadoop.fs.gs.GoogleHadoopFileSystem; do
  run "javap -classpath \"\$SPARK_HOME/jars/*\" '$class' >/dev/null" \
    || { echo "FAIL: connector class does not resolve: $class"; exit 1; }
done

echo "==> [$IMAGE] Python 3.11"
python_version="$(run 'python3 --version 2>&1')"
grep -q 'Python 3.11' <<<"$python_version" || { echo "FAIL: Python is not version 3.11: $python_version"; exit 1; }

echo "==> [$IMAGE] spark home directory is writable"
passwd_entry="$(run 'getent passwd spark')"
grep -q ':/home/spark:' <<<"$passwd_entry" || { echo "FAIL: spark home is not /home/spark: '$passwd_entry'"; exit 1; }
run 'test -w /home/spark' || { echo "FAIL: /home/spark is not writable by spark"; exit 1; }

echo "==> [$IMAGE] \$SPARK_HOME ownership"
spark_home_owner="$(run 'stat -c %U:%G $SPARK_HOME')"
[[ "$spark_home_owner" == "spark:spark" ]] || { echo "FAIL: unexpected \$SPARK_HOME ownership: '$spark_home_owner'"; exit 1; }

echo "==> [$IMAGE] UTF-8 locale"
charmap="$(run 'locale charmap')"
[[ "$charmap" == "UTF-8" ]] || { echo "FAIL: expected UTF-8, got '$charmap'"; exit 1; }

if [[ "$CUDA_MODE" == "--cuda" ]]; then
  echo "==> [$IMAGE] CUDA_VERSION=$PINNED_CUDA_VERSION"
  cuda_env="$(docker inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^CUDA_VERSION=' || true)"
  [[ "$cuda_env" == "CUDA_VERSION=$PINNED_CUDA_VERSION" ]] || { echo "FAIL: unexpected CUDA_VERSION: '$cuda_env'"; exit 1; }

  echo "==> [$IMAGE] NV_CUDNN_VERSION=$PINNED_CUDNN_VERSION"
  cudnn_env="$(docker inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^NV_CUDNN_VERSION=' || true)"
  [[ "$cudnn_env" == "NV_CUDNN_VERSION=$PINNED_CUDNN_VERSION" ]] || { echo "FAIL: unexpected NV_CUDNN_VERSION: '$cudnn_env'"; exit 1; }

  echo "==> [$IMAGE] com.iguazio.cuda-version / com.iguazio.cudnn-version labels"
  cuda_label="$(docker inspect "$IMAGE" --format '{{index .Config.Labels "com.iguazio.cuda-version"}}')"
  [[ "$cuda_label" == "$PINNED_CUDA_VERSION" ]] || { echo "FAIL: unexpected com.iguazio.cuda-version label: '$cuda_label'"; exit 1; }
  cudnn_label="$(docker inspect "$IMAGE" --format '{{index .Config.Labels "com.iguazio.cudnn-version"}}')"
  [[ "$cudnn_label" == "$PINNED_CUDNN_VERSION" ]] || { echo "FAIL: unexpected com.iguazio.cudnn-version label: '$cudnn_label'"; exit 1; }

  echo "==> [$IMAGE] nvcc release 12.8"
  nvcc_version="$(run 'nvcc --version 2>&1')"
  grep -Fq 'release 12.8' <<<"$nvcc_version" || { echo "FAIL: CUDA toolkit is not 12.8: $nvcc_version"; exit 1; }

  echo "==> [$IMAGE] cuDNN 9 libraries present"
  run 'ldconfig -p | grep -q libcudnn.so.9' || { echo "FAIL: libcudnn.so.9 not found"; exit 1; }

  echo "==> [$IMAGE] NVIDIA_VISIBLE_DEVICES=all"
  visible_devices="$(docker inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^NVIDIA_VISIBLE_DEVICES=' || true)"
  [[ "$visible_devices" == "NVIDIA_VISIBLE_DEVICES=all" ]] || { echo "FAIL: unexpected NVIDIA_VISIBLE_DEVICES: '$visible_devices'"; exit 1; }

  echo "==> [$IMAGE] NVIDIA_DRIVER_CAPABILITIES=compute,utility"
  caps="$(docker inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^NVIDIA_DRIVER_CAPABILITIES=' || true)"
  [[ "$caps" == "NVIDIA_DRIVER_CAPABILITIES=compute,utility" ]] || { echo "FAIL: unexpected NVIDIA_DRIVER_CAPABILITIES: '$caps'"; exit 1; }
fi

echo "==> [$IMAGE] all checks passed"
