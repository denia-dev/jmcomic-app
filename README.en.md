<p align="center">
  <img src="JMReader/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="JM Reader icon">
</p>

<h1 align="center">JM Reader</h1>

<p align="center">A clean, ad-free third-party reader for JMComic<br>Native on iOS and Android, plus a no-install web version</p>

<p align="center"><a href="README.md">简体中文</a> | <strong>English</strong></p>

> Unofficial client, not affiliated with JMComic. For study and personal use only. A JMComic account is required (register on the official site first); favourites and history sync with your account.

## Why use it

- **Zero ads**: no splash screens, banners or pop-ups — open it and read
- **Truly native**: Swift on iOS and Kotlin on Android, each implemented natively, no web wrappers
- **Cloud sync**: favourites and reading history follow your account across devices
- **Web version, no install**: install a configuration profile and read — on iOS it works without signing

## Features

- Home recommendations, Guess You Like, category browsing, search (type / sort filters, direct JM ID lookup)
- Comic reader: vertical scrolling, tap to immerse, pull-down chapter transition, automatic image descrambling, next-chapter preloading
- My Bookshelf: import local comics and novels (CBZ / ZIP / RAR / PDF / EPUB / TXT), local reading + recent reading
- Novel reader: scroll / page-turn modes, EPUB illustrations placed in their original positions, live page count
- Sign-in, daily check-in, cloud favourites (multiple folders), reading history, reading stats
- Offline downloads
- Tag and author blocking, filtered automatically in lists
- API routes update automatically, with speed test and manual switching

## Download & install

Grab the latest build from [Releases](https://github.com/denia-dev/jmcomic-app/releases/latest) — one release contains everything:

| Platform | File | How to install |
| --- | --- | --- |
| iOS | `JMReader-unsigned.ipa` | Self-sign with a tool like LCSign (iOS 16+) |
| iOS (no signing) | `JMReader.mobileconfig` | Install the profile, then open the web version from the home-screen icon |
| Android | `JMReader-Android-….apk` | Install directly (Android 8.0+) |

Or open the web version right in your browser: https://my-modules.peimingliang8.workers.dev/jm/index.html

## Version history

See [CHANGELOG.md](CHANGELOG.md).
