APP        := WardenHelper
VERSION    ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 1.0)
MIN_MACOS  := 27.0
ARCH       := arm64
BUILD      := build
BUNDLE     := $(BUILD)/$(APP).app
SOURCES    := $(sort $(wildcard Sources/*.swift))
# The root helper: its own sources, plus the protocol file it shares with the app.
HELPER      := warden-helper-daemon
HELPER_ID   := com.warden-helper.helper
HELPER_SRC  := Sources/BlockProtocol.swift $(sort $(wildcard Helper/*.swift))
FRAMEWORKS := -framework Cocoa -framework Foundation -framework SystemConfiguration \
              -framework Network -framework UserNotifications -framework ServiceManagement \
              -framework UniformTypeIdentifiers

.PHONY: all run install uninstall release zip clean help

# Apple silicon (Mac mini M4) only, macOS 27+. No universal/lipo step.
all: bundle

# Assemble the .app and ad-hoc sign it.
bundle:
	@test -n "$(SOURCES)" || { echo "No sources found in Sources/"; exit 1; }
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@echo "==> Compiling $(ARCH)"
	@swiftc -O -target $(ARCH)-apple-macos$(MIN_MACOS) $(FRAMEWORKS) \
		-o $(BUNDLE)/Contents/MacOS/$(APP) $(SOURCES)
	@echo "==> Compiling helper $(ARCH)"
	@swiftc -O -target $(ARCH)-apple-macos$(MIN_MACOS) -framework SystemConfiguration \
		-o $(BUNDLE)/Contents/Resources/$(HELPER) $(HELPER_SRC)
	@# Helper gets a fixed identifier; the copy installed to /Library keeps this signature.
	@out=$$(codesign -f -s - -i $(HELPER_ID) $(BUNDLE)/Contents/Resources/$(HELPER) 2>&1) || { echo "$$out"; exit 1; }
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@printf "APPL????" > $(BUNDLE)/Contents/PkgInfo
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/; \
	 else echo "(no Resources/AppIcon.icns - using default icon)"; fi
	@# Dark-mode variant, swapped in at runtime by AppIconTheme.
	@if [ -f Resources/AppIconDark.icns ]; then cp Resources/AppIconDark.icns $(BUNDLE)/Contents/Resources/; fi
	@# Ad-hoc signing gives the app a stable identity (needed for notifications). No --deep: the helper keeps its own signature.
	@out=$$(codesign -f -s - $(BUNDLE) 2>&1) || { echo "$$out"; exit 1; }
	@echo "==> Built $(BUNDLE)"

run: all
	@-pkill -x $(APP) 2>/dev/null; sleep 0.3
	open $(BUNDLE)

install: all
	@-pkill -x $(APP) 2>/dev/null; sleep 0.3
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "==> Installed to /Applications/$(APP).app"

uninstall:
	@-pkill -x $(APP) 2>/dev/null
	rm -rf /Applications/$(APP).app

# Distributable zip (arm64, ad-hoc signed) + SHA256 for a Homebrew cask.
release: all
	@xattr -cr $(BUNDLE)
	@ditto -c -k --keepParent $(BUNDLE) $(BUILD)/$(APP)-$(VERSION).zip
	@echo "==> $(BUILD)/$(APP)-$(VERSION).zip"
	@shasum -a 256 $(BUILD)/$(APP)-$(VERSION).zip

# Source zip -> ~/Downloads and reveal in Finder.
zip:
	zip -r -X WardenHelper.zip Helper tools Makefile *.md Resources Sources \
		-x "*.DS_Store" -x "__MACOSX/*" -x "*.pyc" -x "*__pycache__*" \
	&& mv -f WardenHelper.zip ~/Downloads/ \
	&& open ~/Downloads/

clean:
	rm -rf $(BUILD)

help:
	@echo "make            build (arm64, macOS $(MIN_MACOS)+) -> $(BUNDLE)"
	@echo "make run        build and launch"
	@echo "make install    build -> /Applications"
	@echo "make release    zip + sha256"
	@echo "make zip        source zip -> ~/Downloads"
	@echo "make clean      remove build/"