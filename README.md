# voca_youtube_player

A lightweight Flutter widget for playing YouTube videos within a
specific time range (clip mode).

This package uses WebView and the YouTube IFrame API to enable short,
controlled video playback scenarios such as language learning apps, quiz
flows, and micro-content experiences.

------------------------------------------------------------------------

## Features

-   Play only between selected seconds (`startSeconds` to `endSeconds`)
-   Controlled startup flow until the first visual frame is ready
-   Optional custom control overlay (`showControls`)
-   Optional UI reduction strategies (`hideLogo`, `hideAdvice`)
-   End-of-clip countdown (`timerCount`) with completion callback
-   Playback lifecycle callbacks:
    -   `onReadyToPlay`
    -   `onPlaybackStarted`
    -   `onTimerCompleted`
-   Option to open the video externally (YouTube app or browser)

------------------------------------------------------------------------

## Installation

Add the package to your `pubspec.yaml`:

``` yaml
dependencies:
  voca_youtube_player: ^0.0.2
```

Then run:

``` bash
flutter pub get
```

------------------------------------------------------------------------

## Basic Usage

``` dart
import 'package:flutter/material.dart';
import 'package:voca_youtube_player/voca_youtube_player.dart';

class ExamplePage extends StatelessWidget {
  const ExamplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
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
            debugPrint('Clip completed');
          },
        ),
      ),
    );
  }
}
```

------------------------------------------------------------------------

## Parameters

  --------------------------------------------------------------------------------
  Parameter             Type              Required          Description
  --------------------- ----------------- ----------------- ----------------------
  `appId`               `String?`         No                Optional domain/app
                                                            identifier used to
                                                            build origin and
                                                            `widget_referrer`.
                                                            Defaults to
                                                            `https://localhost`.

  `videoId`             `String`          Yes               YouTube video ID.

  `startSeconds`        `double`          Yes               Clip start time in
                                                            seconds.

  `endSeconds`          `double`          Yes               Clip end time in
                                                            seconds.

  `hideLogo`            `bool`            No                Attempts to reduce
                                                            YouTube logo/title
                                                            visibility. Default:
                                                            `false`.

  `hideAdvice`          `bool`            No                Attempts to reduce
                                                            end-screen
                                                            suggestions. Default:
                                                            `false`.

  `showControls`        `bool`            No                Enables or disables
                                                            the custom control
                                                            overlay. Default:
                                                            `true`.

  `timerCount`          `int`             No                End-of-clip countdown
                                                            start value. Disabled
                                                            when less than or
                                                            equal to zero.

  `onReadyToPlay`       `VoidCallback?`   No                Triggered when the
                                                            player is ready.

  `onPlaybackStarted`   `VoidCallback?`   No                Triggered when the
                                                            first visual frame is
                                                            considered started.

  `onTimerCompleted`    `VoidCallback?`   No                Triggered when the
                                                            countdown reaches
                                                            zero.
  --------------------------------------------------------------------------------

------------------------------------------------------------------------

## Playback Flow

1.  The widget initializes WebView and loads the YouTube IFrame API.
2.  When `READY_TO_PLAY` is received, `onReadyToPlay` is triggered.
3.  Playback seeks to `startSeconds`.
4.  When the first visual frame is detected, `onPlaybackStarted` is
    triggered.
5.  Playback pauses before the full YouTube end-screen recommendations.
6.  If `timerCount` is greater than zero, countdown begins and
    `onTimerCompleted` is triggered when it reaches zero.

------------------------------------------------------------------------

## Platform Support

-   Android
-   iOS

Web and desktop platforms are not officially supported due to WebView
limitations.

------------------------------------------------------------------------

## Notes

-   This package depends on YouTube IFrame API behavior. Future YouTube
    changes may affect UI or playback behavior.
-   `hideLogo` and `hideAdvice` are reduction strategies and may not
    fully remove all overlays in every scenario.
-   Autoplay and gesture behavior may vary by device and WebView
    version.

------------------------------------------------------------------------

## License

MIT
