# Builds Finder — a Cocoa bundle, no Xcode project needed.
# clang ships with the Command Line Tools; if it's missing:
#   xcode-select --install
#
# The product is the .app bundle and nothing else. A bare Mach-O executable is
# claimed by Terminal when double-clicked in Finder; a bundle is launched by
# LaunchServices, which gives no terminal window and no Dock icon (LSUIElement).

CC      ?= clang
CFLAGS  ?= -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
LDFLAGS ?= -framework Cocoa -framework Foundation

SRC     := Finder.m
HEADERS := FinderIcon.h
APP     := build/Finder.app
PLIST   := $(APP)/Contents/Info.plist
BIN     := $(APP)/Contents/MacOS/Finder

all: app

app: $(BIN)
	@$(MAKE) --no-print-directory sync
	codesign --force --sign - $(APP) 2>/dev/null || true
	@echo "built $(APP) — launch with: open $(APP)"

$(PLIST):
	@mkdir -p $(APP)/Contents
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '  <key>CFBundleName</key><string>Finder</string>' \
	  '  <key>CFBundleDisplayName</key><string>Finder</string>' \
	  '  <key>CFBundleIdentifier</key><string>local.Finder</string>' \
	  '  <key>CFBundleExecutable</key><string>Finder</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>1.0</string>' \
	  '  <key>CFBundleVersion</key><string>1</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>11.0</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '</dict>' \
	  '</plist>' > $(PLIST)

$(BIN): $(SRC) $(HEADERS) $(PLIST)
	@mkdir -p $(APP)/Contents/MacOS
	$(CC) $(CFLAGS) -o $(BIN) $(SRC) $(LDFLAGS)

# Copy the project's blocklist into the bundle. The sheet reads its own bundle,
# which is never gated by macOS; reading ~/Downloads from the app raises the
# system's folder-permission alert on the first OK press, which would give the
# dialog away. Run this after editing Finder-blocklist.txt.
sync:
	@mkdir -p $(APP)/Contents/Resources
	@if [ -f Finder-blocklist.txt ]; then \
	  cp Finder-blocklist.txt $(APP)/Contents/Resources/Finder-blocklist.txt; \
	  echo "synced Finder-blocklist.txt -> $(APP)/Contents/Resources"; \
	else \
	  echo "no Finder-blocklist.txt in this directory — nothing to sync"; \
	fi
	@codesign --force --sign - $(APP) 2>/dev/null || true

# Launch through LaunchServices — same path as double-clicking the bundle.
run: app
	open $(APP)

selftest: $(BIN)
	$(BIN) --selftest

focuscheck: $(BIN)
	$(BIN) --focuscheck

typecheck: $(BIN)
	$(BIN) --typecheck

shakecheck: $(BIN)
	$(BIN) --shakecheck

entercheck: $(BIN)
	$(BIN) --entercheck

blocklist: $(BIN)
	@$(BIN) --blocklist-path
	@open -e "Finder-blocklist.txt"

# The full verification run, also written to ~/Downloads/Finder-check.txt so the
# results can be opened without a terminal. The file holds pass/fail metrics from
# fixtures compiled into the binary -- no typed input is recorded anywhere.

check: $(BIN)
	@set +e; { \
	  printf '# Finder verification — %s\n' "$$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; \
	  printf '# host %s, macOS %s\n' "$$(hostname)" "$$(sw_vers -productVersion)"; \
	  printf '# Synthetic fixtures only — nothing typed by a person appears here.\n\n'; \
	  $(BIN) --selftest;   s1=$$?; \
	  $(BIN) --focuscheck; s2=$$?; \
	  $(BIN) --typecheck;  s3=$$?; \
	  $(BIN) --shakecheck;   s4=$$?; \
	  $(BIN) --entercheck;   s5=$$?; \
	  printf '\nselftest=%s focuscheck=%s typecheck=%s shakecheck=%s entercheck=%s\n' \
	         "$$s1" "$$s2" "$$s3" "$$s4" "$$s5"; \
	  test "$$s1" -eq 0 -a "$$s2" -eq 0 -a "$$s3" -eq 0 -a "$$s4" -eq 0 -a "$$s5" -eq 0; \
	} ; rc=$$?; \
	exit $$rc

# Rebuild the embedded icon bytes from a PNG crop (99x90 px, the reference's own).
icon: icon_ref.png
	xxd -i -n kIconPNG icon_ref.png > FinderIcon.h

clean:
	rm -rf build

.PHONY: all app sync run selftest focuscheck typecheck shakecheck entercheck blocklist check icon clean
