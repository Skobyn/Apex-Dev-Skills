#!/usr/bin/env bash
set -euo pipefail
exec python3 -I -c 'import json, ssl, urllib.request, hashlib, fcntl, math, os, sys; sys.stdout.write(json.dumps({"scored":False,"reason":"backend_none"})+"\n")'
