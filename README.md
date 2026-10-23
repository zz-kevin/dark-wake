# Dark Wake

Dark Track, at sea. An iOS app that fuses two independent views of a stretch
of water into one tracked picture, then flags vessels that behave as though
they don't want to be seen:

- **AIS**: the cooperative source. Ships broadcast identity (MMSI, name,
  type), position, speed and course. Live from [aisstream.io](https://aisstream.io)
  or from the built-in simulator.
- **Coastal radar** (simulated): the non-cooperative source. It sees hulls,
  not names: noisy polar plots, a radar horizon that hides small boats
  sooner than ships, detection probability that falls with range, sea clutter.

A vessel that switches its AIS off while the radar keeps tracking it is the
maritime "went dark", and is the main thing this app is for. Ships do it to
hide illegal fishing, sanctions-busting ship-to-ship transfers and smuggling.

<p align="center">
  <img src="docs/ipad.png" alt="Dark Wake on iPad: Dover Strait picture with two vessels flagged as gone dark" height="520">
  &nbsp;
  <img src="docs/iphone.png" alt="Dark Wake on iPhone: the same simulation on a phone layout" height="520">
</p>
<p align="center"><sub>Dover Strait simulation on iPad (A16) and iPhone 16 Pro. Blue arrows are
vessels reporting AIS; red ones have gone dark while the South Foreland radar
(green ring) still tracks them; yellow diamonds are radar contacts with no AIS
at all.</sub></p>

<p align="center">
  <img src="docs/running.gif" alt="Dark Wake running: ships move through the Dover Strait and two of them turn red as they go dark" width="480">
</p>
<p align="center"><sub>25 seconds at 60&times;, about 19 simulated minutes. It opens with every
vessel on AIS; two of them switch AIS off partway through, are flagged red
within about a minute of simulated time, and the alert count climbs from 1 to 4.</sub></p>

## What it flags

| Alert | Rule |
|---|---|
| **Went dark** | AIS silent longer than max(60 s, 3x that vessel's own reporting interval), while radar has put a plot on the track in the last 30 s *and* on at least half the sweeps since AIS stopped. Anchored and moored vessels are excluded, as are vessels last seen at the edge of the feed's area. |
| **AIS gap (unconfirmed)** | AIS silent 10 min or more outside radar cover, where both the last fix and the dead-reckoned position are well inside the area, so the vessel didn't just sail out of it. |
| **AIS position jump** | Consecutive reports more than 2 km apart at an implied speed over 60 kn (spoofing or a misconfigured transponder). |
| **Dark rendezvous** | Two tracks held within 500 m for 5 min with their midpoint drifting under 2 kn, at least one of them dark or radar-only (a ship-to-ship transfer). |
| **Kinematic anomaly** | Kalman innovation beyond 4σ of the filter's own innovation std, twice in a row from one source (Dark Track's `kinematic_inconsistency`). |
| **No-AIS contact** | A confirmed radar track that has never had an AIS identity. |

## How it maps to Dark Track

| Dark Track | Dark Wake |
|---|---|
| `fusion/kalman.py` | `Core/KalmanFilter.swift`: constant-velocity filter, AIS SOG/COG fed in as a velocity measurement |
| `fusion/associate.py` | `Core/FusionEngine.swift`: covariance gate plus fixed radius, 3 km outer limit, NLL cost, Hungarian assignment per sweep (`Core/Hungarian.swift`) |
| `ingestion/radar_model.py` | `Core/CoastalRadar.swift`: one shore site, 4/3-earth horizon, range/azimuth noise, Pd(range, size), clutter |
| `anomaly/detectors.py` | `Core/AnomalyEngine.swift`: episode-based, so one dropout is one alert |
| `anomaly/inject.py` + `harness.py` | `Core/VesselSimulator.swift` (scripted bad actors + ground truth) and `Scorecard` in `Core/Pipeline.swift`; the in-app **Inject AIS dropout** button |
| OpenSky poller | `App/AISStreamClient.swift` + `App/LiveFeed.swift` |

## Measured

`swift test` runs 3 simulated hours in each of the four areas (Dover Strait,
Gibraltar, Singapore Strait, New York Bight). Each run has about 16 transiting
ships, 6 fishing boats, 3 at anchor, a go-fast boat and a no-AIS mothership,
plus scripted dark runs, rendezvous and AIS spoofing:

| | Result |
|---|---|
| Went dark, radar-visible | 89/92 (96.7%) |
| Median time to alert | 62–64 s |
| False went-dark alarms | 0 of 174 vessels |
| Dark rendezvous | 15/15 |
| AIS position jumps | 24/24 |

Two fixes got it there, both kept as comments in the code. First, every
early false alarm was a vessel leaving the area: its coasting track picked up
one stray plot minutes later. That is track seduction, not corroboration, so
the went-dark rule now needs radar on at least half the sweeps since AIS
stopped. Second, rendezvous started at 1/15, because two hulls 150 m apart
swap radar plots and their filter speeds jitter to 2–8 kn. "Stopped" is now
judged from the pair's midpoint drift over the window.

These numbers come from this project's own simulator, so treat them as a
regression baseline, not a claim about real traffic.

**Live mode** was tested on a physical iPad (A16) on 2026-10-23. It
connected to aisstream.io and showed real ships, and an injected AIS
dropout on a real vessel was flagged as went dark. That was one injection,
so it shows the live path works end to end; it is not a detection rate.

## Running it

**Tests** (no simulator needed):

```bash
swift test
```

**App:** open `DarkWake.xcodeproj` in Xcode 16 or later and run the
`DarkWake` scheme on an iOS 17+ simulator or device, or on *My Mac (Mac
Catalyst)*. If Xcode reports that no iOS simulator runtime is installed, add
one under Xcode › Settings › Components.

**Live AIS:** get a free key at aisstream.io, then in the app go to Settings ›
Live AIS, paste the key and tap *Apply and restart*. The key is stored in the
Keychain.

## Known limitations

- **In live mode the radar is derived from AIS.** A vessel that really
  switches AIS off also disappears from this radar, so real-world dropouts
  surface as *AIS gap (unconfirmed)*. The radar-confirmed path is tested
  with *Inject AIS dropout*, which hides a vessel's AIS from fusion while the
  radar keeps seeing it (the same approach as Dark Track's `inject.py`).
- aisstream.io is terrestrial AIS, so coverage thins out offshore and quiet
  patches there are normal.
- The simulator knows nothing about land, so in some areas vessels cross it.
- Constant-velocity filter only (no IMM). Ships manoeuvre gently enough that
  this hasn't been a problem in simulation.
- Equirectangular local projection: fine across one radar's ~50 km
  coverage, not across an ocean.
