PREFIX ?= $(HOME)/.local
APP_DIR ?= $(HOME)/Applications
APP_NAME = LoudStation.app
EXECUTABLE = LoudStation
COMMAND = loudstation
LABEL = io.github.juanjsebgarcia.loudstation
# Without an explicit target swiftc stamps the build machine's macOS as the minimum, so the
# binaries would refuse to run on anything older. Keep in step with LSMinimumSystemVersion.
SWIFTC = swiftc -O -swift-version 5 -target arm64-apple-macos13
CORE = $(wildcard Sources/Core/*.swift)
LPROJ = $(wildcard Resources/*.lproj/*)
APP_STAMP = build/.app-stamp
UNLOAD = launchctl bootout "gui/$$(id -u)/$(LABEL)" 2>/dev/null || true; pkill -x $(EXECUTABLE) || true

all: build/$(COMMAND) $(APP_STAMP)

app: $(APP_STAMP)

build/$(COMMAND): $(CORE) Sources/CLI/main.swift
	mkdir -p build
	$(SWIFTC) -o $@ $^
	codesign --force --options runtime --sign - $@

# A stamp file stands in for the bundle, which make cannot track as a whole.
$(APP_STAMP): $(CORE) Sources/App/main.swift Resources/Info.plist Resources/AppIcon.icns $(LPROJ)
	rm -rf "build/$(APP_NAME)"
	mkdir -p "build/$(APP_NAME)/Contents/MacOS" "build/$(APP_NAME)/Contents/Resources"
	$(SWIFTC) -o "build/$(APP_NAME)/Contents/MacOS/$(EXECUTABLE)" $(CORE) Sources/App/main.swift
	cp Resources/Info.plist "build/$(APP_NAME)/Contents/Info.plist"
	cp Resources/AppIcon.icns "build/$(APP_NAME)/Contents/Resources/"
	cp -R Resources/*.lproj "build/$(APP_NAME)/Contents/Resources/"
	codesign --force --options runtime --sign - "build/$(APP_NAME)"
	touch $@

# Unit tests (pure Core logic), CLI tests, validator tests and translation validation. Nothing
# here probes or cycles a display, and the log and state folder go to a temporary folder.
test: build/$(COMMAND) $(APP_STAMP) build/unit-tests
	@scratch=$$(mktemp -d) && \
	export LOUDSTATION_STATE_DIR="$$scratch/state" LOUDSTATION_LOG="$$scratch/test.log" && \
	LOUDSTATION_STRINGS_BUNDLE=Tests/Fixtures/Strings.bundle LOUDSTATION_TEST_APP="build/$(APP_NAME)" build/unit-tests -AppleLanguages '(en)' && \
	bash Tests/cli.sh build/$(COMMAND) "build/$(APP_NAME)" && \
	python3 -I -m unittest discover -s Tests -p 'test_*.py' && \
	python3 -I Tools/localize.py --check; \
	status=$$?; rm -rf "$$scratch"; exit $$status

build/unit-tests: $(CORE) Tests/Unit/main.swift
	mkdir -p build
	$(SWIFTC) -o $@ $^

# Regenerate Resources/*.lproj and Sources/Core/EnglishStrings.swift after editing Localization/.
strings:
	python3 Tools/localize.py

# Regenerate Resources/AppIcon.icns and docs/icon.png after changing Tools/make-icon.swift.
icon:
	swift Tools/make-icon.swift

# launchd restarts the app on an unsuccessful exit, so the job is booted out before the app
# is stopped; the app recreates its login item on the next launch.
install: all
	mkdir -p "$(PREFIX)/bin" "$(APP_DIR)"
	install -m 755 build/$(COMMAND) "$(PREFIX)/bin/$(COMMAND)"
	$(UNLOAD)
	rm -rf "$(APP_DIR)/$(APP_NAME)"
	cp -R "build/$(APP_NAME)" "$(APP_DIR)/"
	open "$(APP_DIR)/$(APP_NAME)"
	@echo "Installed. Look for the LoudStation icon in the menu bar; it opens at every login from now on."
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; *) echo "Note: $(PREFIX)/bin is not on your PATH. Add it to use the $(COMMAND) command, for example: echo 'export PATH=\"$(PREFIX)/bin:\$$PATH\"' >> ~/.zshrc";; esac

uninstall:
	$(UNLOAD)
	rm -f "$(HOME)/Library/LaunchAgents/$(LABEL).plist"
	rm -rf "$(APP_DIR)/$(APP_NAME)" "$(PREFIX)/bin/$(COMMAND)"
	rm -rf "$(HOME)/Library/Application Support/LoudStation"
	rm -f "$(HOME)/Library/Logs/loudstation.log" "$(HOME)/Library/Logs/loudstation.log.1"
	defaults delete $(LABEL) 2>/dev/null || true
	@echo "Uninstalled, including settings and the log."

clean:
	rm -rf build

.PHONY: all app test strings icon install uninstall clean
