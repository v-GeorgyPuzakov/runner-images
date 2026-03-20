#!/bin/bash -e -o pipefail
################################################################################
##  File:  install-llvm.sh
##  Desc:  Install LLVM
################################################################################

source ~/utils/utils.sh

llvmVersion=$(get_toolset_value '.llvm.version')

brew_smart_install "llvm@${llvmVersion}"

echo "Ensuring Apple clang remains the default compiler"
brew unlink "llvm@${llvmVersion}"

invoke_tests "LLVM"
