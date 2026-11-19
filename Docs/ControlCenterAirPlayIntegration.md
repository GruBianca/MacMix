# MacMix Control Center AirPlay integration (development branch)

This branch ports the system-output AirPlay connection workflow that was
manually verified on a MacBook Neo with a HomePod mini to MacMix.

**Status: MacMix integration source code written, not yet compiled or
end-to-end tested in Xcode.** The Terminal and FineTune experiments are
evidence for the underlying Accessibility control sequence only.

## Reused existing MacMix capabilities

- `AirPlayReceiverBrowser` already discovers nearby receivers over
  `_airplay._tcp` Bonjour, without requiring the receiver to appear in
  Core Audio.
- `AirPlayDataSources` and `CoreAudioHardware` already resolve selected
  receiver names for the shared AirPlay HAL output, including receiver groups.
- `OutputAudioState.unlistedAirPlayReceivers` already suppresses many
  duplicates between connected and nearby outputs.
- `MenuBarPanelCoordinator` already owns the menu bar popup's
  `isPresented` binding.

No receiver name such as "卧室" is hard-coded in this branch.

## New system-output flow

1. The user clicks the **AirPlay icon** on an unconnected receiver row in
   MacMix's menu bar Output section.
2. If Accessibility permission is missing, macOS displays its authorization
   prompt and opens Accessibility settings. The user must grant access.
3. `ControlCenterAirPlayAutomation` locates the Control Center status item,
   opens the system Sound → AirPlay picker, and selects the receiver by its
   dynamically discovered name.
4. The app waits for a stable system-wide AirPlay output. It uses the selected
   name decoded by MacMix's Core Audio model; when HAL reports only a generic
   AirPlay output, it also checks the system's selected receiver row.
5. On confirmed connection it attempts to close the two levels of the system
   Control Center, then uses `MenuBarPanelCoordinator.isPresented` to reopen
   the **MacMix** panel.
6. Output device rows update from the existing Core Audio listener. The
   temporary Bonjour row disappears when a receiver is represented by HAL.

`AXPress == 0` is not itself a connection confirmation. The loop polls
every 250 ms for up to 20 seconds and requires three consecutive confirmed
observations.

The app-output routing picker is intentionally *not* replaced. This workflow
switches the whole Mac's default output, not just one application's media.

## Other UI fixes

The full menu-bar panel now has a height limit based on the current screen's
visible frame and a vertical `ScrollView`. It should remain usable when
output, input and per-app mixing sections are all expanded.

## macOS identifiers measured

| Role | AXIdentifier | Operation |
| --- | --- | --- |
| Control Center menu extra | `com.apple.menuextra.controlcenter` | `AXPress` |
| Sound module | `module-Sound` | Container |
| AirPlay audio button | `controlcenter-airplay` | `AXPress` |
| Receiver | `sound-device-<receiverName>` | `AXPress` |

These are UI identifiers, not a stable public API contract. Different macOS
versions and multi-display configurations may require adaptation.

## Local Xcode acceptance checklist

1. Launch MacMix without its standalone macOS Sound menu bar item enabled.
2. Grant Local Network access for Bonjour discovery, if prompted.
3. Verify the nearby receiver name is dynamic and the trailing action is the
   AirPlay icon.
4. Click a receiver. Grant Accessibility access if prompted, and try again.
5. Confirm the system picker opens, chooses the requested receiver, and the
   default system output actually changes.
6. Confirm the receiver name displays in the existing connected device row,
   and the nearby duplicate disappears.
7. Confirm both system panels close and the MacMix menu bar panel reappears.
8. Switch back to the built-in speakers. Confirm the Bonjour receiver can
   be offered again.
9. Expand Now Playing, Output, Mix and Input, and verify scrolling works on
   a short-height screen.
10. Regression-test Bluetooth discovery, volume controls and per-app routing.

Run the repository's regression commands as documented in CONTRIBUTING.md:

```sh
for test in tests/run-*.sh; do bash "$test"; done
swift test --package-path Packages/MacMixStudio
```

## Known limitations

- Accessibility permission is granted to the application by the user;
  it cannot be enabled silently.
- Control Center may change its accessibility tree in future macOS builds.
- The menu bar entrance hit-test currently assumes the control is on the
  main display's upper-right area.
- For an AirPlay HAL output with no readable receiver name, the existing
  MacMix UI may still show a generic `AirPlay` label. Never replace it
  with an unverified hard-coded receiver name.
- If the default output never confirms the desired route, the operation
  times out rather than claiming success.
