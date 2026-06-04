# cacophony

Sound classification from the command line, powered by native macOS SoundAnalysis.

Classify 300+ types of sounds from audio files or live microphone input. Dogs barking, glass breaking, sirens, laughter, musical instruments, speech, rain — all recognized on-device using Apple's built-in sound classifier. No API keys, no downloads, no network calls.

Written in Zig. Uses Apple's SoundAnalysis and AVFoundation frameworks via Objective-C runtime bindings.

## Install

### Homebrew

```bash
brew install georgemandis/tap/cacophony
```

### From source

Requires [Zig 0.16+](https://ziglang.org/download/) and macOS.

```bash
git clone https://github.com/georgemandis/cacophony.git
cd cacophony
zig build -Doptimize=ReleaseFast
```

## Usage

### Classify an audio file

```bash
$ cacophony classify recording.wav
0.9792  speech
0.5980  sigh
0.5331  mosquito_buzz
0.4602  insect
0.4339  click

$ cacophony classify song.mp3 --top=3 --json
[{"label":"music","confidence":0.9812},{"label":"guitar","confidence":0.7234},{"label":"singing","confidence":0.6891}]
```

### Listen to the microphone

```bash
$ cacophony listen
Listening for 5.0s...
0.5530  sneeze
0.4091  wind_instrument
0.3979  speech
0.3402  saxophone
0.3345  music

$ cacophony listen --duration=3000 --threshold=0.5 --top=3
Listening for 3.0s...
0.8234  dog_bark
0.6012  animal
0.5891  domestic_animal
```

### List all sound categories

```bash
$ cacophony categories | head -10
speech
shout
yell
battle_cry
children_shouting
screaming
whispering
laughter
baby_laughter
giggling

$ cacophony categories | wc -l
303

$ cacophony categories --json | jq '.[0:5]'
["speech","shout","yell","battle_cry","children_shouting"]
```

## Composability

```bash
# Check if a recording contains speech
cacophony classify recording.wav --top=1 | grep speech

# Monitor for specific sounds
cacophony listen --duration=10000 --json | jq '.[] | select(.label == "dog_bark")'

# Search for a sound category
cacophony categories | grep drum
```

## Options

```
cacophony <command> [options]

Commands:
  classify <file>    Classify sounds in an audio file
  listen             Classify sounds from the microphone
  categories         List all recognized sound categories

Options:
  --top=N            Show top N classifications (default: 5)
  --threshold=N      Minimum confidence 0.0-1.0 (default: 0.0)
  --duration=MS      Listen duration in ms (default: 5000)
  --json             Output as JSON
  --help, -h         Show this help message
  --version, -v      Show version
```

## Requirements

- macOS 10.15+ (Catalina or later)
- Zig 0.16+

## How It Works

cacophony uses Apple's [SoundAnalysis](https://developer.apple.com/documentation/soundanalysis) framework with the built-in Version 1 sound classifier, which recognizes 303 sound categories.

- **File analysis:** `SNAudioFileAnalyzer` loads audio files via `AVAudioFile` and runs classification synchronously
- **Live mic:** `AVAudioEngine` captures microphone input, feeding audio buffers to `SNAudioStreamAnalyzer` via an audio tap
- **Observer pattern:** Runtime class creation (`objc_allocateClassPair`) implementing `SNResultsObserving` protocol
- **Block ABI:** ObjC block construction (`_NSConcreteStackBlock`) for the audio engine tap callback

## Related Projects

- [lingua](https://github.com/georgemandis/lingua) — NLP CLI (NaturalLanguage framework)
- [tezcatl](https://github.com/georgemandis/tezcatl) — Headless web rendering CLI (WebKit)
- [loupe](https://github.com/georgemandis/loupe) — Computer vision CLI (Vision framework)
- [whereami](https://github.com/georgemandis/whereami) — Location CLI (CoreLocation)
- [nearme](https://github.com/georgemandis/nearme) — Local search CLI (MapKit)

## Credits

Created by [George Mandis](https://george.mand.is) during [Recurse Center](https://www.recurse.com/).
