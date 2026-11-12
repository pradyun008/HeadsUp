#!/bin/sh
# Exports YOLO11n to Core ML with NMS built in, into HeadsUp/Resources/.
# Needs uv (https://docs.astral.sh/uv/). Run from the repo root: sh tools/export_model.sh
set -e
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python ultralytics coremltools "numpy<=2.3.5"
mkdir -p .venv/work && cd .venv/work
../bin/yolo export model=yolo11n.pt format=coreml nms=True
rm -rf ../../HeadsUp/Resources/yolo11n.mlpackage
cp -R yolo11n.mlpackage ../../HeadsUp/Resources/
echo "Model at HeadsUp/Resources/yolo11n.mlpackage"
