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
# Compares CPU and CUDA image environments. CUDA runtime variables and the
# intentional omission of Spark build-provenance variables are allowed.

set -euo pipefail

CPU_IMAGE="${1:?usage: env-parity.sh <cpu-image> <cuda-image>}"
CUDA_IMAGE="${2:?usage: env-parity.sh <cpu-image> <cuda-image>}"

image_env() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}'
}

lookup() {
  local env_text="$1"
  local key="$2"
  local line

  while IFS= read -r line; do
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <<<"$env_text"
  return 1
}

cpu_env="$(image_env "$CPU_IMAGE")"
cuda_env="$(image_env "$CUDA_IMAGE")"

echo "==> comparing shared image environment"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  key="${line%%=*}"
  cpu_value="${line#*=}"

  case "$key" in
    SPARK_TGZ_URL|SPARK_TGZ_ASC_URL|GPG_KEY)
      if lookup "$cuda_env" "$key" >/dev/null; then
        echo "FAIL: CUDA image unexpectedly contains $key"
        exit 1
      fi
      ;;
    PATH)
      cuda_value="$(lookup "$cuda_env" "$key")" || {
        echo "FAIL: CUDA image is missing $key"
        exit 1
      }
      [[ ":$cuda_value:" == *":/usr/local/cuda/bin:"* ]] || {
        echo "FAIL: CUDA PATH is missing /usr/local/cuda/bin"
        exit 1
      }
      normalized_cuda_path="${cuda_value/:\/usr\/local\/cuda\/bin/}"
      [[ "$normalized_cuda_path" == "$cpu_value" ]] || {
        echo "FAIL: PATH differs beyond the expected CUDA addition"
        echo "CPU:  $cpu_value"
        echo "CUDA: $cuda_value"
        exit 1
      }
      ;;
    *)
      cuda_value="$(lookup "$cuda_env" "$key")" || {
        echo "FAIL: CUDA image is missing $key"
        exit 1
      }
      [[ "$cuda_value" == "$cpu_value" ]] || {
        echo "FAIL: $key differs"
        echo "CPU:  $cpu_value"
        echo "CUDA: $cuda_value"
        exit 1
      }
      ;;
  esac
done <<<"$cpu_env"

echo "==> checking CUDA-only environment allowlist"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  key="${line%%=*}"

  if lookup "$cpu_env" "$key" >/dev/null; then
    continue
  fi

  case "$key" in
    NV_*|CUDA_*|NVIDIA_*|NVARCH|NCCL_VERSION|LD_LIBRARY_PATH|LIBRARY_PATH)
      ;;
    *)
      echo "FAIL: unexpected CUDA-only environment variable: $key"
      exit 1
      ;;
  esac
done <<<"$cuda_env"

echo "==> CPU/CUDA environment parity passed"
