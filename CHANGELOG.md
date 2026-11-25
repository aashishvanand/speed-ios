# Changelog

Each entry is one TestFlight build of the iOS, tvOS and macOS apps, labelled
`version (build)` as set by `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
in `project.yml`. Version 1.0 hasn't shipped to the App Store yet, so its
store "What's New" text stays "First release."

## 1.0 (2) — 2026-11-25

### Accessibility

- **Increase Contrast:** the quality grades (Great, Good, Average, Poor, Bad)
  now follow the system setting. Light mode uses darker shades and dark mode
  paler ones, all at least 7:1 against their card.
- **VoiceOver on the Mac now reads the numbers.** macOS was dropping the value
  from combined elements, so the download hero, the stat chips and the history
  rows were read without their figures ("Download" instead of "Download, 412
  Mbps"). On the Mac the value is now part of the label.

### Testing

- New Mac UI test target, `CFSpeedMacUITests`, covering the result screen's
  accessibility tree, the map being hidden from VoiceOver, and the History
  sheet. It runs from the `CFSpeed-macOS` scheme.

### TestFlight: what to test

```
- Turn on Increase Contrast (Settings → Accessibility → Display & Text Size on iPhone/iPad, System Settings → Accessibility → Display on Mac) and check the grade colours in light and dark mode.
- On the Mac, turn on VoiceOver and check that the download and upload speeds, the latency and jitter chips, and each History row are read with their numbers.
```

## 1.0 (1) — 2026-11-20

First TestFlight build.

- Speed test against speed.cloudflare.com: download, upload, idle and loaded
  latency, and jitter, with network quality grades for video streaming,
  online gaming and video chatting.
- Live throughput graph, a map of the server location, and your network's ISP.
- History saved on the device, with a detail view per result and CSV export.
- Data use: Start Tests Automatically can be turned off, the result shows how
  much data a run used, and a manual start on a metered connection asks first.
- iPhone, iPad, Apple TV and Mac apps sharing one bundle ID.
- Accessibility: VoiceOver labels throughout, Dynamic Type, Reduce Motion,
  and grade colours that clear 4.5:1 in light mode.
