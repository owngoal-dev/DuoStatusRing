// tw_config.h — the compile-time identity every target shares. build-ios.sh
// passes TW_PACKAGE_ID (build.env PACKAGE_ID) and TW_VERSION (version.txt) on
// every compile; there is deliberately no fallback, so a compile that missed
// them fails here instead of shipping under some other package id.
#pragma once

#ifndef TW_PACKAGE_ID
#error "TW_PACKAGE_ID is not defined; build through scripts/build-ios.sh (it comes from build.env PACKAGE_ID)"
#endif
#ifndef TW_VERSION
#error "TW_VERSION is not defined; build through scripts/build-ios.sh (it comes from configuration/version.txt)"
#endif
