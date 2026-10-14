#!/usr/bin/env bash
# Install the Spark guardrails: guarded vLLM launcher, systemd user
# units, site config, and (with sudo) sysctl tuning.
#
#   ./install.sh            # user-level install (no root needed)
#   sudo ./install.sh --sysctl   # also apply /etc/sysctl.d/99-spark.conf
#
# Nothing is started or enabled -- install is safe to run on a live box.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$HOME/.local/share/spark/bin"
unitdir="$HOME/.config/systemd/user"
confdir="${XDG_CONFIG_HOME:-$HOME/.config}/spark"

mkdir -p "$bin" "$unitdir" "$confdir/models" "$HOME/models"

install -m0755 "$src"/scripts/*.sh "$bin/"
install -m0644 "$src"/systemd/user/*.service "$unitdir/"
install -m0644 "$src"/config/models/*.env "$confdir/models/" 2>/dev/null || true
[ -f "$confdir/spark.conf" ] || install -m0644 "$src"/config/spark.conf "$confdir/spark.conf"

systemctl --user daemon-reload

# Keep user services (and their memory budgets) running without a login
# session. Fails gracefully where polkit refuses.
loginctl enable-linger "$USER" 2>/dev/null || true

if [ "${1:-}" = "--sysctl" ]; then
    if [ "$(id -u)" = "0" ]; then
        install -m0644 "$src"/sysctl/99-spark.conf /etc/sysctl.d/99-spark.conf
        sysctl --system >/dev/null
        echo "sysctl: applied /etc/sysctl.d/99-spark.conf"
    else
        sudo install -m0644 "$src"/sysctl/99-spark.conf /etc/sysctl.d/99-spark.conf
        sudo sysctl --system >/dev/null
        echo "sysctl: applied /etc/sysctl.d/99-spark.conf"
    fi
else
    echo "sysctl: skipped. To apply socket/inotify tuning, run:"
    echo "  sudo install -m0644 $src/sysctl/99-spark.conf /etc/sysctl.d/99-spark.conf"
    echo "  sudo sysctl --system"
fi

cat <<EOF

Installed:
  $bin/            launchers + guards
  $unitdir/        vllm-embeddings, vllm-longcontext, vllm-vision-agent, vllm-model@
  $confdir/spark.conf   (edit MODELS_DIR / VLLM_BIN / budgets here)

Next:
  1. Edit $confdir/spark.conf -- point MODELS_DIR and VLLM_BIN at your install.
  2. Drop models under MODELS_DIR (or edit VLLM_MODEL in the units via
     \`systemctl --user edit <unit>\`).
  3. systemctl --user enable --now vllm-embeddings
     systemctl --user start vllm-longcontext   # or run-model.sh vllm-vision-agent
EOF
