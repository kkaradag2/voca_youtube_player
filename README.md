# VocaPlayer

`VocaPlayer` is a Flutter widget for playing YouTube videos within a specific
time range (clip mode). It uses WebView + YouTube IFrame API and adds a custom
control layer for clip-focused playback.

## Features

- Play only between selected seconds (`startSeconds` - `endSeconds`)
- Controlled startup flow until the first visual frame is ready
- Optional custom control overlay (`showControls`)
- Optional logo/recommendation reduction behaviors (`hideLogo`, `hideAdvice`)
- End-of-clip countdown (`timerCount`) with completion callback
- Open in external YouTube app/browser (via menu)
- Callback support: `onReadyToPlay`, `onPlaybackStarted`, `onTimerCompleted`

## Installation

`pubspec.yaml`:

```yaml
dependencies:
  voca_player: ^1.0.0
```

Then run:

```bash
flutter pub get
```

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:voca_player/voca_player.dart';

class ExamplePage extends StatelessWidget {
  const ExamplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: VocaPlayer(
          videoId: 'E0BY209ZNEY',
          startSeconds: 12.0,
          endSeconds: 20.0,
          hideLogo: true,
          hideAdvice: true,
          showControls: true,
          timerCount: 25,
          onReadyToPlay: () {
            debugPrint('Player is ready');
          },
          onPlaybackStarted: () {
            debugPrint('Playback started');
          },
          onTimerCompleted: () {
            debugPrint('End timer completed');
          },
        ),
      ),
    );
  }
}
```

## Parameters

- `appId` (`String?`): Optional app/domain value used to build `origin` and
  `widget_referrer`. If empty, `https://localhost` is used.
- `videoId` (`String`, required): YouTube video ID.
- `startSeconds` (`double`, required): Clip start time in seconds.
- `endSeconds` (`double`, required): Clip end time in seconds.
- `hideLogo` (`bool`, default `false`): Applies masking/preset rules to reduce
  YouTube logo/title visibility.
- `hideAdvice` (`bool`, default `false`): Stops playback near the end to reduce
  YouTube end-screen suggestions.
- `showControls` (`bool`, default `true`): Enables/disables the custom control
  overlay.
- `timerCount` (`int`, default `0`): End countdown start value. Disabled when
  `<= 0`.
- `onReadyToPlay` (`VoidCallback?`): Triggered when player is ready.
- `onPlaybackStarted` (`VoidCallback?`): Triggered when the first visual frame
  is considered started.
- `onTimerCompleted` (`VoidCallback?`): Triggered when countdown reaches zero.

## Playback Flow

1. The widget initializes WebView + YouTube IFrame API.
2. When `READY_TO_PLAY` is received, `onReadyToPlay` is fired.
3. User starts playback, player seeks near `startSeconds`.
4. When the first visual frame is detected, `onPlaybackStarted` is fired.
5. At clip end (especially with `hideAdvice=true`), playback is paused before
   full end-screen recommendations.
6. If `timerCount > 0`, countdown starts and `onTimerCompleted` fires at zero.

## Notes

- This package depends on YouTube IFrame API behavior; upstream YouTube changes
  may affect UI and playback flow.
- `hideLogo` and `hideAdvice` are reduction strategies, not guaranteed full
  removal of all overlays/recommendations in every case.
- On Android, autoplay/gesture behavior may vary by device and WebView version.

## License

MIT
