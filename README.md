<div align="center">
  <img width="160" height="160" src="./Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png" alt="Hangar icon">
  <h1>Hangar</h1>
  <p><i>Run iPhone apps side by side, or install them as real apps, from one simple app.</i></p>
</div>

Hangar is a sideloading app for iOS that combines two things in one place:

- **A container** for unlimited apps. IPA files run inside Hangar without being installed, several at once, with their own Home grid. No 3-app limit and nothing expires.
- **A native installer** for apps that need to be real apps. Hangar signs and installs them with your Apple ID in the background and refreshes their 7-day signature. No separate store app, no extra screens.

Hangar is built on [LiveContainer](https://github.com/LiveContainer/LiveContainer) (the container) and [SideStore](https://github.com/SideStore/SideStore) (the native installer). It started as a fork of both; see [Credits](#credits).

## Features

- **Home:** a grid of your container apps. Tap to open, full screen; a dot shows what's running. Open several apps and switch between them without closing any.
  Touch and hold an app to rename, delete, change its settings, add it to your iPhone's Home Screen, or install it natively.
- **Library:** install an IPA *in the container* or *as a native app*, see native apps with days left and slots used, and refresh them all with one tap.
- **Sources:** browse app sources and install from them.
- **Settings:** Apple ID sign-in (with 2FA, in Hangar's own screen), pairing file import, and how hidden apps behave. Original settings pages are under *Advanced*.
- **Games:** apps run at 120 Hz with Game Mode, hidden apps pause and go quiet (music apps keep playing), and an optional FPS and memory overlay.

## Requirements

- iOS 17 or later (tested on iOS 27.2, iPhone 16 Pro).
- An Apple ID. A free account works: up to 3 native apps at a time and 10 new App IDs a week. Container apps don't count.
- LocalDevVPN from the App Store, switched on when installing or refreshing native apps.
- A pairing file for your iPhone, made once with [iLoader](https://github.com/nab138/iloader) or Wireless Pairing.

## Install

1. Download `LiveContainer+SideStore.ipa` from the latest [build run](../../actions/workflows/build.yml) (Actions → Xcode - Build → artifacts).
2. Install it once with iLoader, keeping app extensions. After that Hangar updates itself: *Library → Install an IPA → As a native app*.
3. Open Hangar → *Settings* → sign in with your Apple ID. Import your pairing file there if Hangar asks for one.

## Build

Every push to `main` builds the IPA on GitHub Actions (`xcode-27` runner, Xcode 27.2), in about 2 minutes. The native installer comes from [Hangar's SideStore build](https://github.com/AbinGanlary/Hangar-Installer/releases/tag/hangar), downloaded during packaging (`.github/build_github.sh`, override with `HANGAR_SIDESTORE_URL`).

Hangar's own code is in `LiveContainerSwiftUI/Combined/` (Home, Library, Settings, sign-in, installer bridge) plus small, marked changes in the original sources (search for `Hangar` or `combined-app fork`).

## Credits

Hangar would not exist without these projects and their contributors:

- [LiveContainer](https://github.com/LiveContainer/LiveContainer): the container, multitasking and app runtime.
- [SideStore](https://github.com/SideStore/SideStore): on-device signing, installing and refreshing (via the [LiveContainer/SideStore](https://github.com/LiveContainer/SideStore) integration).

Please don't report Hangar problems to those projects; open an issue here instead.

## License

Hangar is licensed under the **GNU Affero General Public License v3.0**, like LiveContainer and SideStore. See [LICENSE](LICENSE). The original copyright notices are kept in the source files.
