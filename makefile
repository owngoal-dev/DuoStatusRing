# DuoStatusRing — a MobileSubstrate tweak for jailbroken iOS, packaged for both
# roothide and rootless with the plain Xcode toolchain (no Theos as a build
# system). Every step is a script under scripts/ so CI and a local checkout run
# the same bytes; this makefile only wires them together and owns the per-flavor
# layout.

SHELL := /bin/bash
ROOT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

CONFIG_DIR := $(ROOT_DIR)/configuration
readcfg = $(shell set -a; . "$(CONFIG_DIR)/build.env" >/dev/null 2>&1; echo "$${$(1)}")

TWEAK_NAME := $(call readcfg,TWEAK_NAME)
PACKAGE_ID := $(call readcfg,PACKAGE_ID)
MIN_IOS    := $(call readcfg,MIN_IOS)
PKG_VERSION := $(strip $(shell cat "$(CONFIG_DIR)/version.txt" 2>/dev/null))

BUILD_DIR ?= $(ROOT_DIR)/build
# BUILD_DIR must be absolute and must not live under /tmp/ (Xcode DerivedData
# and FileManager disagree on the /tmp symlink; build-output-and-scratch).
ifeq ($(filter /%,$(BUILD_DIR)),)
$(error BUILD_DIR must be an absolute path, got '$(BUILD_DIR)')
endif
ifneq ($(filter /tmp/%,$(BUILD_DIR)),)
$(error BUILD_DIR must not begin with /tmp/ (use /private/tmp); got '$(BUILD_DIR)')
endif

# build-ios.sh reads BUILD_DIR from the environment; export it so the scripts
# and this makefile always agree on where the products are.
export BUILD_DIR
PKG_DIR := $(BUILD_DIR)/pkg

BUILDER   := $(ROOT_DIR)/scripts/build-ios.sh
PACKAGER  := $(ROOT_DIR)/scripts/package-deb.sh
VERSIONER := $(ROOT_DIR)/scripts/apply-version.sh
INSTALLER := $(ROOT_DIR)/scripts/install-device.sh

DEB_ROOTHIDE := $(PKG_DIR)/$(PACKAGE_ID)_$(PKG_VERSION)_iphoneos-arm64e.deb
DEB_ROOTLESS := $(PKG_DIR)/$(PACKAGE_ID)_$(PKG_VERSION)_iphoneos-arm64.deb
DSYM_ROOTHIDE := $(PKG_DIR)/$(PACKAGE_ID)_$(PKG_VERSION)_iphoneos-arm64e.dSYM.tar.zst
DSYM_ROOTLESS := $(PKG_DIR)/$(PACKAGE_ID)_$(PKG_VERSION)_iphoneos-arm64.dSYM.tar.zst

ifeq ($(PKG_VERSION),)
$(error configuration/version.txt is missing or empty; run make set-version VERSION=x.y.z)
endif

.PHONY: all help checklist check build build-roothide build-rootless \
        debs deb-roothide deb-rootless checksums install probe clean set-version \
        print-version print-package-id
.NOTPARALLEL:

all: debs

help:
	@echo "$(TWEAK_NAME) $(PKG_VERSION) — tweak for jailbroken iOS ($(PACKAGE_ID))"
	@echo "  checklist       Refuse to build until CHECKLIST.md is fully ticked"
	@echo "  check           Run every static gate (scripts, layout, source, docs, no-theos)"
	@echo "  build           Compile both flavors (no packaging)"
	@echo "  debs            Both packages + per-flavor dSYM archives + SHA256SUMS"
	@echo "  install         Install the matching deb on a device over SSH and smoke-test"
	@echo "  probe           (ungated) run a one-off probe script from scripts/, if present"
	@echo "  clean           Remove $(BUILD_DIR)"
	@echo "  make set-version VERSION=1.2.3"

print-version:
	@echo "$(PKG_VERSION)"

print-package-id:
	@echo "$(PACKAGE_ID)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3" >&2; exit 64; }
	@"$(VERSIONER)" "$(VERSION)"

# --- gates ---
checklist:
	@"$(ROOT_DIR)/scripts/check-checklist.sh" "$(ROOT_DIR)/CHECKLIST.md"

check: checklist
	@echo "==> shell syntax"
	@for s in "$(ROOT_DIR)"/scripts/*.sh; do bash -n "$$s" || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck --severity=warning "$(ROOT_DIR)"/scripts/*.sh || true; fi
	@echo "==> config"
	@[[ "$(PKG_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$$ ]] || { echo "error: bad version '$(VERSION)'" >&2; exit 65; }
	@[[ "$(MIN_IOS)" =~ ^[0-9]+\.[0-9]+$$ ]] || { echo "error: bad MIN_IOS '$(MIN_IOS)'" >&2; exit 65; }
	@echo "==> no committed literal version"
	@! grep -RnE '(CFBundleShortVersionString|CFBundleVersion)</key>[[:space:]]*<string>[0-9]' "$(ROOT_DIR)/packaging" "$(ROOT_DIR)/src" 2>/dev/null || { echo "error: committed literal version" >&2; exit 65; }
	@"$(ROOT_DIR)/scripts/check-no-theos.sh"
	@"$(ROOT_DIR)/scripts/check-layout.sh"
	@"$(ROOT_DIR)/scripts/check-source.sh"
	@"$(ROOT_DIR)/scripts/check-docs.sh"
	@echo "ok"

# --- build ---
build-roothide:
	@"$(BUILDER)" --scheme roothide >/dev/null

build-rootless:
	@"$(BUILDER)" --scheme rootless >/dev/null

build: build-roothide build-rootless

# A flavor's deb and dSYM archive are a pair, and SHA256SUMS vouches for the
# whole set: touching either flavor first drops SHA256SUMS and that flavor's
# old pair, and a failure removes whatever half of the pair was written. A
# failed build never leaves a stale deb, dSYM or SHA256SUMS behind.
# pack_flavor <flavor> <deb> <dsym-archive>
define pack_flavor
	@mkdir -p "$(PKG_DIR)"
	@rm -f "$(PKG_DIR)/SHA256SUMS" "$(2)" "$(3)"
	@"$(BUILDER)" --scheme $(1) >/dev/null \
		&& "$(PACKAGER)" $(1) "$(BUILD_DIR)/$(1)/product" "$(BUILD_DIR)/$(1)/$(TWEAK_NAME).dylib.dSYM" "$(2)" \
		&& tar --zstd -cf "$(3)" -C "$(BUILD_DIR)/$(1)" "$(TWEAK_NAME).dylib.dSYM" \
		|| { rm -f "$(2)" "$(3)"; exit 1; }
endef

deb-roothide:
	$(call pack_flavor,roothide,$(DEB_ROOTHIDE),$(DSYM_ROOTHIDE))

deb-rootless:
	$(call pack_flavor,rootless,$(DEB_ROOTLESS),$(DSYM_ROOTLESS))

# The set is rebuilt from nothing: a failure anywhere leaves no build/pkg, so
# nothing half-built can be installed or uploaded.
debs: checklist
	@rm -rf "$(PKG_DIR)"
	@$(MAKE) --no-print-directory deb-roothide deb-rootless checksums || { rm -rf "$(PKG_DIR)"; exit 1; }

checksums:
	@cd "$(PKG_DIR)" && shasum -a 256 \
		"$(notdir $(DEB_ROOTHIDE))" "$(notdir $(DEB_ROOTLESS))" \
		"$(notdir $(DSYM_ROOTHIDE))" "$(notdir $(DSYM_ROOTLESS))" | tee SHA256SUMS

install: debs
	@"$(INSTALLER)" "$(PKG_DIR)"

# Ungated escape hatch for one-off probes (e.g. a .tbd lookup or a failing link);
# never a build or release path. Runs scripts/probe.sh if the author added one.
probe:
	@test -x "$(ROOT_DIR)/scripts/probe.sh" && "$(ROOT_DIR)/scripts/probe.sh" || echo "no scripts/probe.sh"

clean:
	@test -n "$(BUILD_DIR)" && [[ "$(BUILD_DIR)" == /* ]] || { echo "refusing to clean non-absolute BUILD_DIR" >&2; exit 65; }
	rm -rf "$(BUILD_DIR)"
