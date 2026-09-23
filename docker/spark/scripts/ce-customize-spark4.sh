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
# Spark 4 counterpart of ce-customize.sh. Installs Python 3.11, connector JARs
# from the supplied manifest, and a writable home directory for the spark user.
set -ex
export DEBIAN_FRONTEND=noninteractive

JAR_MANIFEST="${1:?usage: ce-customize-spark4.sh <jar-manifest>}"

apt-get update
apt-get install -y --no-install-recommends software-properties-common curl ca-certificates gnupg
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update
apt-get install -y python3.11 python3.11-distutils git
rm -rf /var/lib/apt/lists/*

curl https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
python3.11 /tmp/get-pip.py
rm -f /tmp/get-pip.py

while read -r line || [ -n "$line" ]; do
  url="${line%%#*}"
  url="$(echo "$url" | tr -d '[:space:]')"
  [ -z "$url" ] && continue
  case "$url" in
    https://*) ;;
    *) echo "bad manifest line: $line" >&2; exit 1 ;;
  esac
  curl -fsSL -o "/opt/spark/jars/$(basename "$url")" "$url"
done < "$JAR_MANIFEST"

update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
ln -sf /usr/bin/python3 /usr/bin/python

usermod -d /home/spark spark
mkdir -p /home/spark
chown spark:spark /home/spark
