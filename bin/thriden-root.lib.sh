# thriden-root.lib.sh -- the host facts forge-web cannot discover for itself.
# Sourced (not executed) by thriden-upgrade.sh, thriden-redeploy.sh and
# thriden-deploy-payload.sh -- every wrapper that can recreate forge-web.
#
# TWO facts now, and the file name only names the first: THRIDEN_HOST_ROOT
# (where is this checkout?) and THRIDEN_HOST_RELEASE (which umbrella release is
# it on?). The name is kept because renaming would churn three `# shellcheck
# source=` directives, three call sites and a deploy-manifest entry to describe
# a file whose actual job -- "supply what the container is structurally blind
# to" -- has not changed. Add the third fact here too rather than minting a
# sibling lib: a second library is a second thing every future forge-web-
# recreating wrapper must remember to source, and a var set by one wrapper and
# unset by another churns the container on alternate runs.
#
# ⚠ The two facts have OPPOSITE inheritance rules, deliberately. Read the
# THRIDEN_HOST_RELEASE block at the foot of this file before reconciling them.
#
# Why: forge-web renders operator commands that invoke scripts out of the
# Thriden checkout (`<root>/bin/thriden-scion-up.sh <id>`, `...-down.sh`,
# `...-upgrade.sh`), and it genuinely CANNOT discover <root> itself. It runs in
# a container with no bind-mount of the checkout and deliberately no docker
# socket, so there is no filesystem to stat and no docker API to interrogate.
# The host has to tell it. PF resolves it as a ladder
# (PersonaForge forge/admin/thriden_host.py):
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

# ── THRIDEN_HOST_RELEASE — which umbrella release is this tree on? ───────────
#
# The second host fact forge-web cannot discover for itself, and it fails the
# same way the root did (/ ThridenOps-3xs1). forge-web's
# release verdict compared component IMAGE pins only, so thriden-v0.23.1 --
# which moved no pins at all (forge v0.25.0, engram v0.13.1, nooscope v0.8.0 all
# unchanged; the entire payload was bin/ deploy scripts) -- rendered "up to
# date, nothing to apply" and REPLACED the apply affordance, while the notes on
# the same screen described scripts the host did not have. Composed with
# sleep-ineligible (correct: the scheduled path delivers images, it does not run
# a deploy script) that release had no offered application path at all.
#
# The umbrella tag was the one thing in a Thriden release with no representation
# on the host: `grep -rn 'THRIDEN_VERSION|THRIDEN_RELEASE'` over yml/sh/env/md
# returned zero on 2026-08-21. deploy/versions.env pins the five component
# versions and never names the umbrella they came from.
#
# MEASURED, NOT AUTHORED -- and that is the whole argument for deriving this
# from git rather than adding a THRIDEN_VERSION= line to deploy/versions.env.
# versions.env is an INSTRUCTION (which images to run), so authored-and-shipped
# is right for it. This is a MEASUREMENT (what is this tree actually at), and an
# authored string can assert "v0.24.0 applied" on a tree that is demonstrably
# not at v0.24.0, with nothing on the host able to contradict it. A claim whose
# instrument is the claim itself is the failure this stack has a whole knowledge
# file about; `git describe` is an instrument that reads the subject.
#
# Three deliberate flags, each of which has a wrong-looking obvious alternative:
#
#   --match 'thriden-v*'  the repo also carries engram `v*` tags on the same
#                         history. Unfiltered describe would report an engram
#                         version as the umbrella. (Same trap already noted at
#                         thriden-deploy-payload.sh's THRIDEN_RUN_FROM.)
#
#   NO --abbrev=0         THRIDEN_RUN_FROM uses --abbrev=0 because it feeds a
#                         semver comparison and needs a bare X.Y.Z. Here it
#                         would be actively harmful: it reports the bare tag on
#                         a tree N commits PAST that tag, turning "I am
#                         somewhere after v0.23.1" into the confident claim "I
#                         am v0.23.1". Plain describe yields
#                         `thriden-v0.23.1-2-gabc1234`, which PF renders as
#                         reported-but-state-unknown. A tree past its tag is
#                         real information; do not round it off.
#
#   NO --dirty            looks like the honest choice and is unusable here.
#                         Every deploy runs `sops set`/`unset` on
#                         secrets/prod/stack.enc.env, and SOPS re-encryption is
#                         non-deterministic, so EVERY production host is
#                         git-dirty after ANY deploy -- even a clean one
#                         (the same fact git_sync_to_tag excludes
#                         secrets/ for). --dirty would therefore pin every real
#                         host at "unknown" forever and read as a broken
#                         feature. Commit drift is captured; working-tree dirt
#                         deliberately is not.
#
# `git -C "$THRIDEN_HOST_ROOT"` rather than relying on cwd, for exactly the
# reason the root derivation above avoids $PWD: correct regardless of where the
# operator invoked the wrapper from, and regardless of which wrapper sourced us.
#
# ⚠ ALWAYS RE-DERIVED. NEVER INHERITED. This is the deliberate opposite of the
# THRIDEN_HOST_ROOT rule twenty lines up, so do not "make them consistent".
# Two reasons, and the first is a live bug rather than a principle:
#   1. thriden-deploy-payload.sh sources this library BEFORE its cry2 self-sync
#      checks out the payload's thriden_version and re-execs. An inherited value
#      would survive that re-exec and report the tag the host was on BEFORE the
#      deploy -- the stalest possible answer, produced by the exact path whose
#      job is to advance the tree. (thriden-upgrade.sh is not exposed: it sources
#      us after its step-1b re-exec.)
#   2. An override is meaningful for the root because the root is configuration
#      -- the operator genuinely knows where they installed it. There is no
#      corresponding thing an operator knows better than git does about which
#      commit their tree is at, so an override here could only ever launder a
#      false value into the UI.
#
# Underivable (no git, no .git, shallow clone with no tags, an operator-set
# THRIDEN_HOST_ROOT that is not a checkout) exports PRESENT AND EMPTY, matching
# the root's contract: PF treats empty as unset, does not vote the row, and the
# page degrades precisely to its pre-hir3 behaviour rather than to a wrong one.
THRIDEN_HOST_RELEASE=""
if command -v git >/dev/null 2>&1 && [ -n "${THRIDEN_HOST_ROOT:-}" ]; then
  # Guarded + `|| true` so this can never trip a caller's `set -e`. Same rule as
  # the root above: a convenience rung must never abort a deploy, and this one
  # runs unattended inside a torpor window on the scheduled path.
  THRIDEN_HOST_RELEASE="$(git -C "$THRIDEN_HOST_ROOT" describe --tags \
    --match 'thriden-v*' 2>/dev/null || true)"
fi
export THRIDEN_HOST_RELEASE
