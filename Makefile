PROJECT := pomme.xcodeproj
CONFIG := Release
BUILD := $(CURDIR)/build
PRODUCT := $(BUILD)/$(CONFIG)/pomme
INSTALL_DIR ?= $(HOME)/.local/bin
PKG_VERSION ?= $(shell sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' Config/Shared.xcconfig | head -1)

.PHONY: all build cli sign pkg install uninstall clean
all: build
build: install
cli:
	xcodebuild -project $(PROJECT) -scheme pomme -configuration $(CONFIG) -arch arm64 SYMROOT=$(BUILD) build
	test -x "$(PRODUCT)"
sign: cli
	codesign --verify --strict --verbose=2 "$(PRODUCT)"
pkg:
	Scripts/build-release-pkg.sh --version "$(PKG_VERSION)" --dist-dir "$(BUILD)"
install: sign
	mkdir -p "$(INSTALL_DIR)"
	ln -sfn "$(PRODUCT)" "$(INSTALL_DIR)/pomme"
uninstall:
	rm -f "$(INSTALL_DIR)/pomme"
clean:
	xcodebuild -project $(PROJECT) -scheme pomme -configuration $(CONFIG) -arch arm64 SYMROOT=$(BUILD) clean
	rm -rf "$(BUILD)"
