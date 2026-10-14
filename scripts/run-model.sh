#!/usr/bin/env bash
# Convenience switcher for mutually-exclusive port-8000 models:
# stops the other model services, then starts the requested one.
#
#   run-model.sh vllm-longcontext
#   run-model.sh vllm-vision-agent
set -euo pipefail

target="${1:?usage: run-model.sh <systemd-user-service>}"
target="${target%.service}"

peers="vllm-longcontext vllm-vision-agent"

for p in $peers; do
    [ "$p" = "$target" ] && continue
    systemctl --user stop "$p" 2>/dev/null || true
done
sleep 2

systemctl --user start "$target"
echo
systemctl --user status "$target" --no-pager -l | head -15 || true
echo
echo "Logs: tail -f /tmp/${target}.log"
