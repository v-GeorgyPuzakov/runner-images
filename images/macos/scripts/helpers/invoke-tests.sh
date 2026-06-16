#!/bin/bash -e -o pipefail

source $HOME/.bashrc
# Invoke-PesterTests throws on a real test failure, which makes pwsh exit with a
# non-zero code. On success it returns normally, but pwsh would otherwise
# propagate a leaked non-zero $LASTEXITCODE produced by native commands executed
# inside the tests (e.g. via Get-CommandResult), failing the build even though
# every test passed. Explicitly exit 0 after a successful run so the build only
# fails when tests actually fail.
pwsh -Command "Import-Module '$HOME/image-generation/tests/Helpers.psm1' -DisableNameChecking
        Invoke-PesterTests -TestFile \"$1\" -TestName \"$2\"
        exit 0"
