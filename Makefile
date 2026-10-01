APP        := WardenHelper
VERSION    ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 1.0)
MIN_MACOS  := 13.0
BUILD      := build
BUNDLE     := $(BUILD)/$(APP).app
SOURCES    := $(sort $(wildcard Sources/*.swift))
# The root helper: its own sources, plus the protocol file it shares with the app.
HELPER      := warden-helper-daemon
HELPER_ID   := com.warden-helper.helper
HELPER_SRC  := Sources/BlockProtocol.swift $(sort $(wildcard Helper/*.swift))
HOST_ARCH  := $(shell uname -m)
FRAMEWORKS := -framework Cocoa -framework Foundation -framework SystemConfiguration \
              -framework Network -framework UserNotifications -framework ServiceManagement \
              -framework UniformTypeIdentifiers

.PHONY: all universal run install uninstall release zip clean help

all:
	@$(MAKE) --no-print-directory bundle ARCHS="$(HOST_ARCH)"

universal:
	@$(MAKE) --no-print-directory bundle ARCHS="arm64 x86_64"

# Internal: build $(ARCHS) slices, merge, assemble the .app, ad-hoc sign.
bundle:
	@test -n "$(SOURCES)" || { echo "No sources found in Sources/"; exit 1; }
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@for a in $(ARCHS); do \
		echo "==> Compiling $$a"; \
		swiftc -O -target $$a-apple-macos$(MIN_MACOS) $(FRAMEWORKS) \
			-o $(BUILD)/$(APP)-$$a $(SOURCES) || exit 1; \
	done
	@lipo -create -output $(BUNDLE)/Contents/MacOS/$(APP) $(foreach a,$(ARCHS),$(BUILD)/$(APP)-$(a))
	@rm -f $(foreach a,$(ARCHS),$(BUILD)/$(APP)-$(a))
	@for a in $(ARCHS); do \
		echo "==> Compiling helper $$a"; \
		swiftc -O -target $$a-apple-macos$(MIN_MACOS) -framework SystemConfiguration \
			-o $(BUILD)/$(HELPER)-$$a $(HELPER_SRC) || exit 1; \
	done
	@lipo -create -output $(BUNDLE)/Contents/Resources/$(HELPER) $(foreach a,$(ARCHS),$(BUILD)/$(HELPER)-$(a))
	@rm -f $(foreach a,$(ARCHS),$(BUILD)/$(HELPER)-$(a))
	@# Signed on its own first (fixed identifier); the copy installed to /Library keeps this signature.
	@codesign --force --sign - --identifier $(HELPER_ID) $(BUNDLE)/Contents/Resources/$(HELPER)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@printf "APPL????" > $(BUNDLE)/Contents/PkgInfo
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/; \
	 else echo "(no Resources/AppIcon.icns - using default icon)"; fi
	@# Dark-mode variant, swapped in at runtime by AppIconTheme.
	@if [ -f Resources/AppIconDark.icns ]; then cp Resources/AppIconDark.icns $(BUNDLE)/Contents/Resources/; fi
	@# Ad-hoc signing gives the app a stable identity; needed for notifications to register.
	@codesign --force --deep --sign - $(BUNDLE)
	@echo "==> Built $(BUNDLE)"

run: all
	@-pkill -x $(APP) 2>/dev/null; sleep 0.3
	open $(BUNDLE)

install: universal
	@-pkill -x $(APP) 2>/dev/null; sleep 0.3
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "==> Installed to /Applications/$(APP).app"

uninstall:
	@-pkill -x $(APP) 2>/dev/null
	rm -rf /Applications/$(APP).app

# Distributable zip (universal, ad-hoc signed) + SHA256 for a Homebrew cask.
release: universal
	@xattr -cr $(BUNDLE)
	@ditto -c -k --keepParent $(BUNDLE) $(BUILD)/$(APP)-$(VERSION).zip
	@echo "==> $(BUILD)/$(APP)-$(VERSION).zip"
	@shasum -a 256 $(BUILD)/$(APP)-$(VERSION).zip

# Source zip -> ~/Downloads and reveal in Finder.
zip:
	zip -r -X WardenHelper.zip Helper tools Makefile *.md Resources Sources Helper tools \
		-x "*.DS_Store" -x "__MACOSX/*" -x "*.pyc" -x "*__pycache__*" \
	&& mv -f WardenHelper.zip ~/Downloads/ \
	&& open ~/Downloads/

clean:
	rm -rf $(BUILD)

help:
	@echo "make            build for this Mac ($(HOST_ARCH)) -> $(BUNDLE)"
	@echo "make run        build and launch"
	@echo "make universal  build arm64 + x86_64"
	@echo "make install    universal build -> /Applications"
	@echo "make release    universal zip + sha256"
	@echo "make zip        source zip -> ~/Downloads"
	@echo "make clean      remove build/"