#!/bin/bash
# Regenerate Hermeto-compatible requirements files for kai_mcp_solution_server.
#
# Invoked by dymurray/mta-sync after a successful merge from konveyor/kai so
# the hash-locked requirements.txt stays in step with upstream pyproject.toml
# changes (upstream commits an unhashed file; .gitattributes merge=ours keeps
# our copy on merge, and this script refreshes it). uv.lock is likewise kept via
# merge=ours and refreshed here. Also runs in CI via
# .github/workflows/verify-requirements-txt.yml as the drift detector.
#
# requirements-build-constraints.txt pins wheel-only build deps to a sdist-
# bearing version because pybuild-deps can't introspect wheels.
set -euo pipefail

cd "$(dirname "$0")/../kai_mcp_solution_server"

# Refresh the lockfile from the (post-merge) pyproject.toml so `uv sync` for devs
# stays consistent. requirements.txt/-build.txt are compiled from pyproject directly
# below and don't depend on this, but keeping uv.lock fresh avoids drift.
uv lock

# Resolve for the image we actually ship, not for whoever ran the sync. Without
# these two flags uv resolves against the host interpreter and platform, so the
# committed file depends on the machine: generating on macOS drops the
# linux-only markers (greenlet, jeepney, secretstorage) from a file Hermeto
# feeds into a RHEL9 build, and generating on 3.14 omits what 3.12 needs
# (exceptiongroup and friends). That is also why verify-requirements-txt.yml
# could never pass - it regenerates on 3.12/linux and diffed against a file
# built on 3.14. Keep these in step with the workflow's python-version.
uv pip compile --generate-hashes \
	--python-version 3.12 --python-platform x86_64-unknown-linux-gnu \
	-c requirements-constraints.txt \
	pyproject.toml -o requirements.txt

trap 'rm -f .build-input.tmp' EXIT
cat requirements.txt requirements-build-constraints.txt >.build-input.tmp

# pybuild-deps memoizes sdist build-dep lookups in a shelve under
# $XDG_CACHE_HOME/pybuild-deps. That cache wedges in two ways, both fatal and
# neither self-healing, so every later run fails identically:
#
#   cache.py:26  CACHE_PATH.mkdir(exist_ok=True)  -- no parents=True, so a
#                missing ~/.cache raises FileNotFoundError (seen on CI runners).
#   cache.py:27  shelve.open(...)  -- an interrupted run leaves a shelve that
#                dbm.whichdb() can't identify, raising
#                "dbm.error: db type could not be determined".
#
# Both are recoverable: create the directory up front, and on failure drop the
# shelve and try once more. Only the shelve goes - the sibling per-package
# directories hold downloaded sdists that source.py reads before it reaches for
# the network, and re-fetching those costs minutes.
pybuild_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/pybuild-deps"
mkdir -p "${pybuild_cache}"

# pybuild-deps reaches straight into pip-tools' and pip's internals, and 0.5.0 is
# the last release, so both have to be pinned with it. Unpinned, uvx resolves the
# newest of each and the run dies on whichever API moved:
#
#   pip-tools >=7.6.0  dropped `generate_hashes` from OutputWriter.__init__
#     TypeError: OutputWriter.__init__() got an unexpected keyword argument 'generate_hashes'
#   pip >26.1.2        added a required `allow_editables` to make_requirement_preparer
#     TypeError: RequirementCommand.make_requirement_preparer() missing 1 required
#     keyword-only argument: 'allow_editables'
#
# Only the version pinned here is known to work. It looks fine on a machine that
# happens to have an older `uv tool install pybuild-deps` lying around, because
# uvx reuses that env instead of resolving - which is why this can break for one
# person and not another. Revisit if pybuild-deps ever releases again.
#
# --no-annotate because the `# via` comments are not stable across environments.
# Which parent a build dep gets attributed to depends on whether pybuild-deps
# could parse each sdist's setup.py, and that varies: the same input here and on
# a runner disagreed about whether tomlkit came via uv-dynamic-versioning. The
# pins and hashes were identical, so the drift detector was failing on a comment.
# Nothing installs from an annotation, so drop them and compare what matters.
compile_build_deps() {
	uvx --python 3.12 \
		--from pybuild-deps==0.5.0 --with pip-tools==7.5.3 --with pip==26.1.2 \
		pybuild-deps compile --generate-hashes --no-annotate \
		-o requirements-build.txt .build-input.tmp
}

# Run it out of line rather than in an `if` condition, which would suppress
# set -e for the whole call (shellcheck SC2310).
set +e
compile_build_deps
compile_status=$?
set -e

if [[ ${compile_status} -ne 0 ]]; then
	echo "post-sync: pybuild-deps failed; dropping its memo cache and retrying once" >&2
	find "${pybuild_cache}" -maxdepth 1 -name 'find-build-deps*' -delete
	compile_build_deps
fi
