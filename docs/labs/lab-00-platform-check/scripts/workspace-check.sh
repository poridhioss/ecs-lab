#!/usr/bin/env bash
# Lab 00: what does the Poridhi workspace itself have?
# Run on: workspace.  Output: ~/lab00-output/workspace.txt
mkdir -p ~/lab00-output
exec > >(tee ~/lab00-output/workspace.txt) 2>&1

show() { printf '%-14s ' "$1"; shift; "$@" 2>&1 | head -1 || true; }

echo "== workspace $(date -Is) =="
show hostname   hostname
show whoami     whoami
show pwd        pwd
show os         grep --color=never PRETTY_NAME /etc/os-release
show kernel     uname -r
show cpu/mem    sh -c 'echo "$(nproc) vCPU, $(free -m | awk "/Mem:/{print \$2}") MB"'
for t in python3 pip3 docker terraform aws git rsync jq curl ssh; do
  if command -v "$t" >/dev/null 2>&1; then
    case "$t" in
      terraform) show "$t" terraform -version ;;
      ssh)       show "$t" ssh -V ;;
      *)         show "$t" "$t" --version ;;
    esac
  else
    printf '%-14s MISSING\n' "$t"
  fi
done
show docker-run sh -c 'docker info --format "server {{.ServerVersion}}" 2>&1'
