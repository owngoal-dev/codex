# codex — OpenAI Codex CLI packaged for jailbroken iOS.
#
# Every step is a script under scripts/ so the GitHub Actions workflow and a
# local checkout run the same code. This makefile only wires them together and
# owns the one thing that differs between the two packages: the layout.

SHELL := /bin/bash
ROOT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

CONFIG_DIR := $(ROOT_DIR)/configuration
include $(CONFIG_DIR)/upstream.env

VERSION_FILE    := $(CONFIG_DIR)/version.txt
PACKAGE_VERSION := $(strip $(shell cat "$(VERSION_FILE)" 2>/dev/null))
PACKAGE_ID      ?= wiki.qaq.codex

BUILD_DIR     := $(ROOT_DIR)/build
SRC_DIR       := $(BUILD_DIR)/src
SCRATCH_DIR   := $(BUILD_DIR)/ios-$(ARCH)
BIN_PATH_FILE := $(BUILD_DIR)/bin-path.txt
PKG_DIR       := $(BUILD_DIR)/Packages

SOURCE_PREPARER  := $(ROOT_DIR)/scripts/prepare-source.sh
IOS_BUILDER      := $(ROOT_DIR)/scripts/build-ios.sh
DEB_PACKAGER     := $(ROOT_DIR)/scripts/package-deb.sh
VERSION_APPLIER  := $(ROOT_DIR)/scripts/apply-version.sh
DEVICE_INSTALLER := $(ROOT_DIR)/scripts/install-device.sh

# Which bootstrap layout the .deb is for. roothide is relocated into the jbroot
# it picked this boot and its *C* bootstrap programs resolve unprefixed paths
# inside it via libvroot; a rootless bootstrap lives at a fixed /var/jb that
# every path in the package has to name. One arm64 binary backs both — only
# the layout and the architecture label differ. The Rust binary itself is not
# vroot-linked; runtime shell lookup is a probe, in patches/.
PACKAGE_FLAVOR ?= roothide
ifeq ($(PACKAGE_FLAVOR),roothide)
PACKAGE_PREFIX       :=
PACKAGE_ARCHITECTURE := iphoneos-arm64e
else ifeq ($(PACKAGE_FLAVOR),rootless)
PACKAGE_PREFIX       := /var/jb
PACKAGE_ARCHITECTURE := iphoneos-arm64
else
$(error PACKAGE_FLAVOR must be roothide or rootless, got '$(PACKAGE_FLAVOR)')
endif

DEB_OUTPUT ?= $(PKG_DIR)/$(PACKAGE_ID)_$(PACKAGE_VERSION)_$(PACKAGE_ARCHITECTURE).deb

ifeq ($(PACKAGE_VERSION),)
$(error $(VERSION_FILE) is missing or empty; run make set-version VERSION=x.y.z)
endif

.PHONY: all help print-version print-upstream print-deb-path set-version \
	bump-upstream follow-upstream rebase-patches check source build package deb \
	deb-roothide deb-rootless debs checksums install clean

.NOTPARALLEL:

all: debs

help:
	@echo "codex $(PACKAGE_VERSION) — OpenAI Codex CLI for jailbroken iOS"
	@echo "upstream: $(UPSTREAM_REPO) @ $(UPSTREAM_REF)"
	@echo "target:   $(ARCH)-apple-ios$(MIN_IOS)  rustc $(RUST_TOOLCHAIN)"
	@echo
	@echo "  check          Validate the scripts, the config, and the patch set"
	@echo "  source         Fetch upstream at the pinned ref and apply patches/"
	@echo "  build          Cross-compile the CLI and Code Mode host for iOS"
	@echo "  deb            Package one flavor (PACKAGE_FLAVOR=$(PACKAGE_FLAVOR))"
	@echo "  deb-roothide   Package for roothide (unprefixed, iphoneos-arm64e)"
	@echo "  deb-rootless   Package for rootless (/var/jb, iphoneos-arm64)"
	@echo "  debs           Both packages plus SHA256SUMS — what CI releases"
	@echo "  install        Install onto a device over SSH and smoke-test it"
	@echo "  clean          Remove build/"
	@echo
	@echo "  make set-version VERSION=1.2.3   Set the package version"
	@echo "  make bump-upstream REF=<sha>     Repin upstream and rebuild"
	@echo "  make follow-upstream             Pin to newest stable rust-vX.Y.Z"

print-version:
	@echo "$(PACKAGE_VERSION)"

print-upstream:
	@echo "$(UPSTREAM_REF)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)"

check:
	@echo "==> shell syntax"
	@for script in "$(ROOT_DIR)"/scripts/*.sh; do bash -n "$$script" || exit 1; done
	@if command -v shellcheck >/dev/null; then \
		shellcheck --severity=warning "$(ROOT_DIR)"/scripts/*.sh; \
	else \
		echo "    (shellcheck not installed; syntax check only)"; \
	fi
	@echo "==> config"
	@[[ "$(PACKAGE_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$$ ]] || \
		{ echo "error: version '$(PACKAGE_VERSION)' must look like 1.2.3 or 1.2.3-2" >&2; exit 65; }
	@[[ "$(MIN_IOS)" =~ ^[0-9]+\.[0-9]+$$ ]] || \
		{ echo "error: MIN_IOS '$(MIN_IOS)' must look like 15.0" >&2; exit 65; }
	@[[ "$(UPSTREAM_REF)" =~ ^[0-9a-f]{40}$$ ]] || \
		echo "    warning: UPSTREAM_REF is not a full commit sha; builds are not reproducible"
	@[[ "$(RUSTY_V8_REF)" =~ ^[0-9a-f]{40}$$ ]] || \
		{ echo "error: RUSTY_V8_REF is not a full commit sha" >&2; exit 65; }
	@echo "==> patch set"
	@ls "$(ROOT_DIR)"/patches/*.patch >/dev/null
	@for patch in "$(ROOT_DIR)"/patches/*.patch; do \
		test -s "$$patch" || { echo "error: $$patch is empty" >&2; exit 65; }; \
	done
	@python3 "$(ROOT_DIR)/scripts/test-patches.py"
	@echo "==> packaging inputs"
	@for input in packaging/DEBIAN/control packaging/codex.entitlements \
		packaging/codex.launcher.c packaging/release-notes.md \
		packaging/etc/codex/config.toml scripts/check-skill-policy.sh; do \
		test -f "$(ROOT_DIR)/$$input" || { echo "error: missing $$input" >&2; exit 66; }; \
	done
	@plutil -lint "$(ROOT_DIR)/packaging/codex.entitlements"
	@"$(ROOT_DIR)/scripts/release-notes.sh" "v$(PACKAGE_VERSION)" >/dev/null
	@echo "==> native depiction"
	@python3 -m json.tool "$(ROOT_DIR)/docs/depiction.json" >/dev/null
	@echo "==> skill policy"
	@bash -n "$(ROOT_DIR)/scripts/check-skill-policy.sh"
	@"$(ROOT_DIR)/scripts/check-skill-policy.sh" --self-test \
		--config "$(ROOT_DIR)/packaging/etc/codex/config.toml"
	@test -L "$(ROOT_DIR)/CLAUDE.md" && [[ "$$(readlink "$(ROOT_DIR)/CLAUDE.md")" == AGENTS.md ]] || \
		{ echo "error: CLAUDE.md must be a symlink to AGENTS.md" >&2; exit 65; }
	@echo "ok"

source:
	@"$(SOURCE_PREPARER)" "$(SRC_DIR)"

build: source
	@mkdir -p "$(BUILD_DIR)"
	@"$(IOS_BUILDER)" "$(SRC_DIR)" "$(SCRATCH_DIR)" >"$(BIN_PATH_FILE)"

package:
	@mkdir -p "$(PKG_DIR)"
	@PACKAGE_ID="$(PACKAGE_ID)" "$(DEB_PACKAGER)" \
		"$$(cat "$(BIN_PATH_FILE)")" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(PACKAGE_PREFIX)"

deb: build package

deb-roothide:
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=roothide deb

deb-rootless:
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=rootless deb

debs: build
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=roothide package
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=rootless package
	@$(MAKE) --no-print-directory checksums

checksums:
	@cd "$(PKG_DIR)" && shasum -a 256 \
		"$(PACKAGE_ID)_$(PACKAGE_VERSION)_iphoneos-arm64.deb" \
		"$(PACKAGE_ID)_$(PACKAGE_VERSION)_iphoneos-arm64e.deb" \
		| tee SHA256SUMS

install: debs
	@"$(DEVICE_INSTALLER)" "$(PKG_DIR)"

bump-upstream:
	@test -n "$(REF)" || { echo "usage: make bump-upstream REF=<sha>" >&2; exit 64; }
	@sed -i '' -e "s|^UPSTREAM_REF=.*|UPSTREAM_REF=$(REF)|" "$(CONFIG_DIR)/upstream.env"
	@echo "repinned upstream to $(REF)"
	@$(MAKE) --no-print-directory build

follow-upstream:
	@"$(ROOT_DIR)/scripts/follow-upstream.sh"

# make rebase-patches REF=<sha>            apply patches/ onto <sha>, list rejects
# make rebase-patches REF=<sha> WRITE=1    rewrite patches/ from build/rebase
rebase-patches:
	@test -n "$(REF)" || { echo "usage: make rebase-patches REF=<sha> [WRITE=1]" >&2; exit 64; }
	@"$(ROOT_DIR)/scripts/rebase-patches.sh" "$(REF)" $(if $(WRITE),--write)

clean:
	rm -rf "$(BUILD_DIR)"
