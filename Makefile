.PHONY: app run install test dmg snapshots clean windows-test windows-build windows-package

# Schneller lokaler Build nur für diesen Mac.
app:
	ARCHS=$$(uname -m) ./scripts/build-app.sh

run: app
	-pkill -x Redefluss
	open dist/Redefluss.app

# Bauen und nach /Applications installieren (inkl. Sprachmodell).
install:
	./scripts/install.sh --with-model

test:
	./scripts/fetch-whisper.sh
	swift test

# Release-Build (Universal) + DMG/ZIP in dist/
dmg:
	./scripts/build-app.sh
	./scripts/package.sh

# Screenshots für das README neu rendern.
snapshots: app
	rm -rf snapshots
	dist/Redefluss.app/Contents/MacOS/Redefluss --snapshot snapshots
	magick snapshots/flowbar-idle.png snapshots/flowbar-recording.png snapshots/flowbar-handsfree.png snapshots/flowbar-transcribing.png snapshots/flowbar-meeting.png -append docs/images/flowbar.png
	magick snapshots/onboarding-0.png -resize 80% docs/images/onboarding.png
	magick snapshots/onboarding-3.png -resize 80% docs/images/hotkey.png
	magick snapshots/settings-general.png -resize 80% docs/images/settings.png
	magick snapshots/settings-model.png -resize 80% docs/images/models.png

clean:
	rm -rf .build dist snapshots

# Windows-Version (windows/): Tests und Kompilieren gehen auch auf dem Mac.
windows-test:
	dotnet test windows/tests/Redefluss.Core.Tests

windows-build:
	dotnet build windows/src/Redefluss.App

windows-package:
	pwsh windows/scripts/publish.ps1
