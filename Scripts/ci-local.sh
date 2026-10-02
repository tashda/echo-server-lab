#!/bin/bash
# The checks CI runs, on this machine: build everything with its tests, then the unit tests.
#
#   Scripts/ci-local.sh            run the checks
#   Scripts/ci-local.sh --install  run them automatically before every `git push`
#
# The integration tests need a lab host and run separately (SERVERLAB_INTEGRATION=1).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--install" ]; then
  hook=".git/hooks/pre-push"
  printf '#!/bin/bash\nexec "$(git rev-parse --show-toplevel)/Scripts/ci-local.sh"\n' > "$hook"
  chmod +x "$hook"
  echo "Installed $hook"
  exit 0
fi

swift build --build-tests
swift test --skip-build --filter "ServerLabKitTests|TDSSpecTests|ServerLabClientTests"
