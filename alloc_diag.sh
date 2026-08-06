#!/usr/bin/env bash
# =====================================================================
# alloc_diag.sh — run alloc_diag.escript against a running EMQX node,
# using EMQX's OWN released erts (escript), so the OTP version and libs
# (ekka_epmd) match the node.
#
# Usage:
#   alloc_diag.sh [--rel <release-dir>] [--conf <emqx.conf>]
#                 [--node <name>] [--cookie <c>] [--verbose]
#
#   --rel     EMQX release dir that contains erts-*  (needed for the
#             escript binary). Default: auto-detect ./emqx, ./_build/...,
#             /opt/emqx (Docker).
#   --conf    path to emqx.conf. Default: $REL/etc/emqx.conf. In
#             production the config is often NOT under the release
#             (e.g. /etc/emqx), so pass --conf (or set EMQX_CONF).
#   --node/--cookie  override node name / cookie.
#
# Node name / cookie are auto-detected in this order:
#   1. generated vm.args under $REL/data/configs/vm.*.args  (what the
#      node actually booted with — e.g. Docker renames the node),
#   2. `emqx_ctl status` output,
#   3. --conf / $REL/etc/emqx.conf.
#   explicit --node / --cookie always win.
#
# Env: EMQX_REL, EMQX_CONF, EMQX_NODE, EMQX_COOKIE
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
    cat <<'EOF'
alloc_diag.sh - EMQX allocator memory diagnostic (run via EMQX's own erts)

Usage:
  alloc_diag.sh [--rel <release-dir>] [--conf <emqx.conf>]
                [--node <name>] [--cookie <c>] [--verbose]

Options:
  --rel <dir>    EMQX release dir containing erts-*   (needed for the
                 escript binary). Default: auto-detect ./emqx,
                 ./_build/emqx-ee/rel/emqx, ./_build/emqx/rel/emqx,
                 /opt/emqx (Docker).
  --conf <path>  path to emqx.conf. Default: $REL/etc/emqx.conf. In
                 production the config is often NOT under the release
                 (e.g. /etc/emqx), so pass --conf (or set EMQX_CONF).
  --node <name>  target node name (overrides auto-detection).
  --cookie <c>   target node cookie (overrides auto-detection).
  --verbose      print per-instance breakdown.
  -h, --help     show this help.

Node name / cookie are auto-detected in this order:
  1. generated vm.args under $REL/data/configs/vm.*.args
  2. `emqx_ctl status`
  3. --conf / $REL/etc/emqx.conf
(explicit --node / --cookie always win)

Env: EMQX_REL, EMQX_CONF, EMQX_NODE, EMQX_COOKIE

Examples:
  ./alloc_diag.sh --rel /opt/emqx
  ./alloc_diag.sh --rel /usr/lib/emqx --conf /etc/emqx/emqx.conf
  docker exec emqx bash /tmp/alloc_diag.sh --rel /opt/emqx
EOF
}

# ---- args ------------------------------------------------------------
REL="${EMQX_REL:-}"
CONF="${EMQX_CONF:-}"
NODE="${EMQX_NODE:-}"
COOKIE="${EMQX_COOKIE:-}"
VERBOSE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rel)    REL="$2"; shift 2 ;;
        --conf)   CONF="$2"; shift 2 ;;
        --node)   NODE="$2"; shift 2 ;;
        --cookie) COOKIE="$2"; shift 2 ;;
        --verbose) VERBOSE="--verbose"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1 (try -h)" >&2; exit 1 ;;
    esac
done

# ---- locate the emqx release (for erts, NOT for config) --------------
if [ -z "$REL" ]; then
    for cand in \
        ./emqx \
        ./_build/emqx-ee/rel/emqx \
        ./_build/emqx/rel/emqx \
        /opt/emqx; do
        if compgen -G "$cand/erts-*" >/dev/null; then
            REL="$cand"; break
        fi
    done
fi
if [ -z "$REL" ] || ! compgen -G "$REL/erts-*" >/dev/null; then
    echo "cannot find emqx release (dir with erts-*) — pass --rel <dir>" >&2
    exit 1
fi
ERTS_DIR="$(ls -d "$REL"/erts-* 2>/dev/null | head -1)"

# ---- conf file -------------------------------------------------------
if [ -z "$CONF" ] && [ -f "$REL/etc/emqx.conf" ]; then
    CONF="$REL/etc/emqx.conf"
fi

# ---- auto-detect node name / cookie ----------------------------------
# 1) generated vm.args (the node actually booted with this)
GEN_ARGS="$(ls -t "$REL"/data/configs/vm.*.args 2>/dev/null | head -1 || true)"
if [ -n "$GEN_ARGS" ] && [ -f "$GEN_ARGS" ]; then
    NODE="${NODE:-$(sed -n 's/^[[:space:]]*-name[[:space:]]\+\(.*\)$/\1/p' "$GEN_ARGS" | head -1)}"
    COOKIE="${COOKIE:-$(sed -n 's/^[[:space:]]*-setcookie[[:space:]]\+\(.*\)$/\1/p' "$GEN_ARGS" | head -1)}"
fi
# 2) emqx_ctl status
if [ -z "$NODE" ] && [ -x "$REL/bin/emqx_ctl" ]; then
    NODE="$("$REL/bin/emqx_ctl" status 2>/dev/null \
        | sed -n "s/^Node '\([^']*\)'.*/\1/p" | head -1 || true)"
fi
# 3) emqx.conf
if [ -n "$CONF" ] && [ -f "$CONF" ]; then
    conf_val() { # $1=key
        sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)/\1/p" \
            "$CONF" | tr -d '"' | tail -1
    }
    NODE="${NODE:-$(conf_val node.name)}"
    COOKIE="${COOKIE:-$(conf_val node.cookie)}"
fi

if [ -z "$NODE" ] || [ -z "$COOKIE" ]; then
    echo "cannot determine node.name / node.cookie" >&2
    echo "  pass --node and --cookie, or --conf <emqx.conf>" >&2
    echo "  (hint: run 'emqx_ctl status' to see the real node name)" >&2
    exit 1
fi

echo "using release: $REL"
echo "using node:    $NODE"
[ -n "$CONF" ] && [ -f "$CONF" ] && echo "using conf:    $CONF"

# ---- run with emqx's own escript ------------------------------------
# ekka_epmd: emqx registers itself via ekka_epmd (deterministic name->port),
# not the OS epmd, so the client must use the same epmd module.
# -boot_var RELEASE_LIB: needed by OTP 28+ boot files; harmless on OTP 24.
export ERL_FLAGS="-start_epmd false -epmd_module ekka_epmd -boot_var RELEASE_LIB \"$REL/lib\""

exec "$ERTS_DIR/bin/escript" "$SCRIPT_DIR/alloc_diag.escript" \
    "$NODE" "$COOKIE" $VERBOSE
