# thriden-root.lib.sh -- shared "where is this checkout on the host?" resolution
# for the deploy tooling. Sourced (not executed) by thriden-upgrade.sh,
# thriden-redeploy.sh and thriden-deploy-payload.sh -- every wrapper that can
# recreate forge-web.
#
# Why: forge-web renders operator commands that invoke scripts out of the
# Thriden checkout (`<root>/bin/thriden-scion-up.sh <id>`, `...-down.sh`,
# `...-upgrade.sh`), and it genuinely CANNOT discover <root> itself. It runs in
# a container with no bind-mount of the checkout and deliberately no docker
# socket, so there is no filesystem to stat and no docker API to interrogate.
# The host has to tell it. PF resolves it as a ladder
# (PersonaForge forge/admin/thriden_host.py, ):
#
#   1. THRIDEN_HOST_ROOT env  -- what this library supplies
#   2. Mongo system_config._id="thriden_host"  -- operator-set at /setup
#   3. /srv/thriden           -- the pi5 layout, and the old hardcoded value
#
# Rung 2 already unblocks any operator by hand. Rung 1 is the one that makes it
# automatic for every install, and only the host side can supply it.
#
# The host side knows the answer by construction: this file lives at
# <root>/bin/, so <root> is exactly one level up from it. Deriving it from $PWD
# would be wrong the moment an operator invokes a wrapper from somewhere other
# than the stack dir; deriving it from ${BASH_SOURCE[0]} is correct regardless
# of cwd AND regardless of which wrapper did the sourcing.
#
# Sourcing this file IS the action -- there is no function to remember to call.
# That is deliberate: a rung whose whole purpose is "nobody has to do anything"
# should not itself depend on someone remembering a second line.
#
# An already-set THRIDEN_HOST_ROOT is left alone. An operator (or a systemd
# unit) that exported one deliberately outranks our derivation, and PF ignores
# a malformed value rather than emitting it -- so a bad export degrades to the
# Mongo/default rungs instead of rendering a broken command.
#
# Note the deliberate asymmetry with THRIDEN_STACK_DIR: that names the
# directory a wrapper operates *in* (compose files, secrets), while this names
# the checkout the operator *invoked*. They are the same directory in every
# normal install. Where they diverge, the script's own location is the correct
# answer here, because it is demonstrably a path where `bin/<script>` exists --
# which is the only thing the rendered commands need.

if [ -n "${THRIDEN_HOST_ROOT:-}" ]; then
  export THRIDEN_HOST_ROOT
elif _thriden_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" \
     && [ -n "$_thriden_root" ]; then
  # Guarded as an `if` condition so a failure can never trip the callers'
  # `set -e`. This is a convenience rung, not a precondition: losing it costs
  # the operator a one-time /setup entry, and must never abort a deploy.
  export THRIDEN_HOST_ROOT="$_thriden_root"
fi
unset _thriden_root
