#!/bin/bash -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

rm -rf venv
python3 -m venv venv
. venv/bin/activate
pip install -r requirements.txt

echo "venv ready. Activate with:  . $script_dir/venv/bin/activate"
