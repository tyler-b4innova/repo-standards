# Sourced from the repository root by test/ci-env. The suite parses workflow files with PyYAML (requirements-dev.txt).
# A python3 that already has it is used as is (CI runners do; no download per run). Otherwise the dependency goes into
# this repository's ignored .test-venv, never into the machine's or the user's Python. The directory carries an owner
# marker holding the requirements it was built from: it is rebuilt when they change, and a .test-venv without the
# marker (not made here) is never removed.
if ! python3 -c "import yaml" 2>/dev/null; then
  venv=.test-venv mark=.test-venv/.owned-by-engine-tests want=$(cat requirements-dev.txt)
  if [ -e "$venv" ] && [ ! -f "$mark" ]; then
    echo "test python: $venv exists but was not made by this suite (no $mark); move it away and rerun" >&2
    return 1
  fi
  if [ ! -x "$venv/bin/python3" ] || [ "$(cat "$mark" 2>/dev/null)" != "$want" ]; then
    rm -rf "$venv" && python3 -m venv "$venv" && : > "$mark" &&
      "$venv/bin/python3" -m pip install -q --disable-pip-version-check -r requirements-dev.txt &&
      printf '%s' "$want" > "$mark" || { echo "test python: could not build $venv from requirements-dev.txt" >&2; return 1; }
  fi
  export PATH="$PWD/$venv/bin:$PATH"
fi
