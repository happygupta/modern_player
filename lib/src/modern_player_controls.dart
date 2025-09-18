import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:modern_player/modern_player.dart';
import 'package:modern_player/src/modern_player_options.dart';
import 'package:modern_player/src/others/modern_player_utils.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'widgets/modern_player_menus.dart';

class ModernPlayerControls extends StatefulWidget {
  const ModernPlayerControls({
    super.key,
    required this.player,
    required this.viewSize,
    required this.videos,
    required this.controlsOptions,
    required this.defaultSelectionOptions,
    required this.themeOptions,
    required this.translationOptions,
    required this.callbackOptions,
    required this.selectedQuality,
    this.title,
    this.subtitle,
  });

  final VlcPlayerController player;
  final Size viewSize;
  final List<ModernPlayerVideoData> videos;
  final ModernPlayerControlsOptions controlsOptions;
  final ModernPlayerDefaultSelectionOptions defaultSelectionOptions;
  final ModernPlayerThemeOptions themeOptions;
  final ModernPlayerTranslationOptions translationOptions;
  final ModernPlayerCallbackOptions callbackOptions;
  final ModernPlayerVideoData selectedQuality;
  final String? title;
  final String? subtitle;

  @override
  State<ModernPlayerControls> createState() => _ModernPlayerControlsState();
}

class _ModernPlayerControlsState extends State<ModernPlayerControls> {
  VlcPlayerController get player => widget.player;
  ModernPlayerTranslationOptions get translationOptions =>
      widget.translationOptions;

  Timer? _statelessTimer;

  /// Debounce timers for preventing rapid clicks
  Timer? _playPauseDebounceTimer;
  Timer? _seekForwardDebounceTimer;
  Timer? _seekBackwardDebounceTimer;
  Timer? _doubleTapDebounceTimer;
  Timer? _seekToDebounceTimer;

  /// Loading timeout timer to prevent indefinite loading states
  Timer? _loadingTimeoutTimer;

  /// Original playback state preservation for consistent behavior across multiple clicks
  bool? _originalPlaybackState;

  /// Operation state tracking to prevent multiple simultaneous operations
  bool _isPlayPauseOperating = false;
  bool _isSeekOperating = false;
  bool _isSeekForwardOperating = false;
  bool _isSeekBackwardOperating = false;

  /// Timing-based click restriction variables for microsecond-level detection
  DateTime? _lastPlayPauseTime;
  DateTime? _lastSeekTime;
  DateTime? _lastSeekForwardTime;
  DateTime? _lastSeekBackwardTime;

  /// Minimum interval between operations (in microseconds) to prevent rapid clicks
  static const int _minOperationIntervalMicroseconds = 100000; // 100ms

  /// Debounce duration for all methods
  static const Duration _debounceDuration = Duration(milliseconds: 300);

  Duration _duration = const Duration();
  Duration _currentPos = const Duration();

  bool _dragLeft = false;
  bool _dragRight = false;

  bool _isLoading = true;
  bool _isBuffering = false;
  bool _wasBuffering = false;
  bool _isDisposed = false;

  double? _brightness;
  double? _volume;
  double? _slidingValue;

  late StreamController<double> _valController;
  late ModernPlayerVideoData _currentVideoData;

  /// Auto hide controls timer
  Timer? _hideTimer;

  /// Check controls is hidden or not
  bool _hideStuff = true;

  /// Offline seek position
  int _seekPos = 0;

  /// List of audio tracks
  Map<int, String>? _audioTracks;

  /// List of subtitle tracks
  Map<int, String>? _subtitleTracks;

  /// List of playback speeds
  final List<double> _playbackSpeeds = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2
  ];

  List<ModernPlayerCustomActionButton> _customActionButtons = [];

  @override
  void initState() {
    _valController = StreamController.broadcast();

    _duration = player.value.duration;
    _currentPos = player.value.position;

    _currentVideoData = widget.selectedQuality;
    _customActionButtons = widget.controlsOptions.customActionButtons ?? [];

    player.addListener(_listen);
    super.initState();
  }

  /// Add listners
  void _listen() async {
    if (!_isDisposed) {
      if (_hideStuff == false) {
        if (_currentPos != player.value.position ||
            player.value.playingState == PlayingState.paused) {
          setState(() {
            _currentPos = player.value.position;
            _duration = player.value.duration;
          });
        }
      } else {
        _currentPos = player.value.position;
        _duration = player.value.duration;
      }

      // Comprehensive buffering detection like video_player_page.dart
      final playingState = player.value.playingState;
      final bufferPercent = player.value.bufferPercent;

      final isCurrentlyBuffering = playingState == PlayingState.buffering ||
          playingState == PlayingState.initializing ||
          (playingState == PlayingState.playing &&
              bufferPercent < 100 &&
              bufferPercent > 0);

      // Only update buffering state if it changed to reduce unnecessary rebuilds
      bool shouldUpdateBuffering = false;
      if (_isBuffering != isCurrentlyBuffering) {
        _wasBuffering = _isBuffering;
        shouldUpdateBuffering = true;
      }

      // Improved loading state reset logic
      if (_isLoading) {
        final playingState = player.value.playingState;
        final bufferPercent = player.value.bufferPercent;

        // Reset loading state when:
        // 1. Player is playing and well buffered (original condition)
        // 2. Player is paused (user might have paused during seek)
        // 3. Player has been buffering for too long (fallback)
        final shouldResetLoading =
            (playingState == PlayingState.playing && bufferPercent >= 100) ||
                playingState == PlayingState.paused ||
                playingState == PlayingState.stopped ||
                playingState == PlayingState.ended;

        if (shouldResetLoading) {
          if (_audioTracks == null && _subtitleTracks == null) {
            _getTracks();
          }

          setState(() {
            _isLoading = false;
          });
        }
      }

      // Update buffering state if needed
      if (shouldUpdateBuffering) {
        setState(() {
          _isBuffering = isCurrentlyBuffering;
        });
      }
    }
  }

  /// Get audio and subtitle tracks
  Future<void> _getTracks() async {
    // Run in parallel - they don't depend on each other.
    final tracksFutures = Future.wait([
      player.getAudioTracks(),
      player.getSpuTracks(),
    ]);

    final results = await tracksFutures;
    _audioTracks = results[0];
    _subtitleTracks = results[1];

    await Future.wait([
      _setDefaultSubtitleTrack(_subtitleTracks),
      _setDefaultAudioTrack(_audioTracks),
    ]);
  }

  /// Helper function to set default track for subtitle, audio, etc
  Future<void> _setDefaultTrack(
      {required List<DefaultSelector>? selectors,
      required Map<int, String>? trackEntries,
      required Function(int) setTrackFunction}) async {
    if (selectors == null || trackEntries == null || trackEntries.isEmpty) {
      return;
    }

    for (final selector in selectors) {
      switch (selector) {
        case DefaultSelectorCustom():
          int? defaultIndex;
          for (final entry in trackEntries.entries) {
            if (selector.shouldUseTrack(entry.key, entry.value)) {
              defaultIndex = entry.key;
              break;
            }
          }

          if (defaultIndex != null) {
            setTrackFunction(defaultIndex);
            return;
            // Else, if no track is found, loop to the next selector
          }
        case DefaultSelectorOff():
          setTrackFunction(-1);
          return;
      }
    }
  }

  /// Set default subtitle track
  Future<void> _setDefaultSubtitleTrack(Map<int, String>? tracks) async {
    await _setDefaultTrack(
      selectors: widget.defaultSelectionOptions.defaultSubtitleSelectors,
      trackEntries: tracks,
      setTrackFunction: player.setSpuTrack,
    );
  }

  /// Set default audio track
  Future<void> _setDefaultAudioTrack(Map<int, String>? tracks) async {
    await _setDefaultTrack(
      selectors: widget.defaultSelectionOptions.defaultAudioSelectors,
      trackEntries: tracks,
      setTrackFunction: player.setAudioTrack,
    );
  }

  /// Toggle between play and pause
  void _playOrPause() async {
    await _executeWithRestriction(
      operationType: 'playPause',
      operation: () async {
        // Cancel any existing debounce timer
        _playPauseDebounceTimer?.cancel();

        // Set up new debounce timer
        _playPauseDebounceTimer = Timer(_debounceDuration, () async {
          if (await player.isPlaying() ?? false) {
            setState(() {
              player.pause();
            });

            widget.callbackOptions.onPause?.call();
          } else {
            setState(() {
              player.play();
            });

            widget.callbackOptions.onPlay?.call();
          }
        });
      },
    );
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(
        widget.controlsOptions.autoHideTime ?? const Duration(seconds: 5), () {
      setState(() {
        _hideStuff = true;
      });
    });
  }

  void _cancelAndRestartTimer() {
    if (_hideStuff == true) {
      _startHideTimer();
    }
    setState(() {
      _hideStuff = !_hideStuff;
    });
  }

  void _changeVideoQuality(ModernPlayerVideoData videoData) async {
    Duration lastPosition = _currentPos;

    await player.pause();

    setState(() {
      _isLoading = true;
    });

    if (videoData.sourceType == VideoSourceType.network) {
      await player.setMediaFromNetwork(videoData.source,
          autoPlay: true, hwAcc: HwAcc.full);
      await player.seekTo(lastPosition);

      if (videoData is ModernPlayerVideoDataYoutube) {
        await player.addAudioFromNetwork(videoData.audioOverride!,
            isSelected: true);
        await _getTracks();
        await player.play();

        setState(() {
          _currentPos = lastPosition;
          _currentVideoData = videoData;
        });
      } else {
        await _getTracks();
        await player.play();

        setState(() {
          _currentPos = lastPosition;
          _currentVideoData = videoData;
        });
      }
    } else if (videoData.sourceType == VideoSourceType.file) {
      await player.setMediaFromFile(File(videoData.source),
          autoPlay: true, hwAcc: HwAcc.full);

      await player.seekTo(lastPosition);
      await player.play();

      setState(() {
        _currentPos = lastPosition;
        _currentVideoData = videoData;
      });
    } else if (widget.videos.first.sourceType == VideoSourceType.youtube) {
      var yt = YoutubeExplode();
      StreamManifest manifest =
          await yt.videos.streamsClient.getManifest(videoData.source);

      VideoStreamInfo streamInfo = manifest.muxed.withHighestBitrate();

      await player.setMediaFromNetwork(streamInfo.url.toString(),
          autoPlay: true, hwAcc: HwAcc.full);
      await player.seekTo(lastPosition);
      await player.play();

      setState(() {
        _currentPos = lastPosition;
        _currentVideoData = videoData;
      });

      yt.close();
    } else {
      await player.setMediaFromAsset(videoData.source,
          autoPlay: true, hwAcc: HwAcc.full);
      await player.seekTo(lastPosition);
      await player.play();

      setState(() {
        _currentPos = lastPosition;
        _currentVideoData = videoData;
      });
    }

    widget.callbackOptions.onChangedQuality
        ?.call(videoData.label, videoData.source);

    // Refresh subtitle and audio tracks
    _getTracks();
  }

  void _changeSubtitleTrack(MapEntry subtitle) async {
    await player.setSpuTrack(subtitle.key);
    widget.callbackOptions.onChangedSubtitle?.call(subtitle.key);
  }

  void _changeAudioTrack(MapEntry subtitle) async {
    await player.setAudioTrack(subtitle.key);
    widget.callbackOptions.onChangedAudio?.call(subtitle.key);
  }

  /// Captures the original playback state before any seek operation
  /// This ensures the video will be set to playing state after seek completion
  Future<void> _captureOriginalPlaybackState() async {
    if (_originalPlaybackState == null) {
      try {
        // Validate player state before capturing
        if (!_isPlayerValid()) {
          debugPrint(
              'Player is not in a valid state for capturing playback state');
          _originalPlaybackState = true; // Default to playing state
          return;
        }

        // Always capture the current state, but we'll restore to playing
        _originalPlaybackState = await player.isPlaying() ?? false;
      } catch (e) {
        debugPrint('Failed to capture original playback state: $e');
        _originalPlaybackState = true; // Default to playing state
      }
    }
  }

  /// Validates if the player is in a valid state for operations
  bool _isPlayerValid() {
    try {
      // Check if player is disposed or not initialized
      if (_isDisposed || !mounted) return false;

      // Check if player has valid duration (indicates media is loaded)
      final duration = player.value.duration;
      if (duration == Duration.zero) return false;

      return true;
    } catch (e) {
      debugPrint('Player validation failed: $e');
      return false;
    }
  }

  /// Generic method to execute operations with click restriction
  Future<void> _executeWithRestriction({
    required String operationType,
    required Future<void> Function() operation,
    Duration? customTimeout,
  }) async {
    final now = DateTime.now();
    
    // Get the appropriate operation flag
    bool isOperating = _getOperationState(operationType);

    // Prevent multiple simultaneous operations
    if (isOperating) {
      debugPrint(
          '$operationType operation already in progress, ignoring click');
      return;
    }

    // Check timing-based restriction to prevent rapid clicks
    DateTime? lastOperationTime = _getLastOperationTime(operationType);
    if (lastOperationTime != null) {
      final timeDifference = now.difference(lastOperationTime).inMicroseconds;
      if (timeDifference < _minOperationIntervalMicroseconds) {
        debugPrint(
            '$operationType operation blocked: only ${timeDifference}μs since last operation (minimum: ${_minOperationIntervalMicroseconds}μs)');
        return;
      }
    }

    // Update last operation time
    _setLastOperationTime(operationType, now);

    try {
      // Set operation state to true
      _setOperationState(operationType, true);

      // Execute the operation with timeout
      await operation().timeout(
        customTimeout ?? const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('$operationType operation timed out');
          throw TimeoutException('$operationType operation timed out',
              customTimeout ?? const Duration(seconds: 5));
        },
      );
    } catch (e) {
      debugPrint('$operationType operation failed: $e');
      rethrow;
    } finally {
      // Always reset operation state
      _setOperationState(operationType, false);
    }
  }

  /// Get operation state for a specific operation type
  bool _getOperationState(String operationType) {
    switch (operationType) {
      case 'playPause':
        return _isPlayPauseOperating;
      case 'seek':
        return _isSeekOperating;
      case 'seekForward':
        return _isSeekForwardOperating;
      case 'seekBackward':
        return _isSeekBackwardOperating;
      default:
        return false;
    }
  }

  /// Set operation state for a specific operation type
  void _setOperationState(String operationType, bool value) {
    if (!mounted) return;

    setState(() {
      switch (operationType) {
        case 'playPause':
          _isPlayPauseOperating = value;
          break;
        case 'seek':
          _isSeekOperating = value;
          break;
        case 'seekForward':
          _isSeekForwardOperating = value;
          break;
        case 'seekBackward':
          _isSeekBackwardOperating = value;
          break;
      }
    });
  }

  /// Get last operation time for a specific operation type
  DateTime? _getLastOperationTime(String operationType) {
    switch (operationType) {
      case 'playPause':
        return _lastPlayPauseTime;
      case 'seek':
        return _lastSeekTime;
      case 'seekForward':
        return _lastSeekForwardTime;
      case 'seekBackward':
        return _lastSeekBackwardTime;
      default:
        return null;
    }
  }

  /// Set last operation time for a specific operation type
  void _setLastOperationTime(String operationType, DateTime time) {
    switch (operationType) {
      case 'playPause':
        _lastPlayPauseTime = time;
        break;
      case 'seek':
        _lastSeekTime = time;
        break;
      case 'seekForward':
        _lastSeekForwardTime = time;
        break;
      case 'seekBackward':
        _lastSeekBackwardTime = time;
        break;
    }
  }

  /// Restores the video to playing state after seek operations complete
  /// This method ensures the video is always set to playing state after seek
  Future<void> _restoreOriginalPlaybackState() async {
    if (_originalPlaybackState == null) return;

    try {
      // Validate player state before attempting restoration
      if (!_isPlayerValid()) {
        debugPrint(
            'Player is not in a valid state for restoring playback state');
        _originalPlaybackState = null;
        return;
      }

      final currentlyPlaying = await player.isPlaying() ?? false;

      // Always set to playing state after seek operations
      if (!currentlyPlaying) {
        debugPrint('Setting video to playing state after seek');
        await player.play().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            throw TimeoutException(
                'Play operation timed out during state restoration',
                const Duration(seconds: 3));
          },
        );

        // Verify the state change was successful
        await Future.delayed(const Duration(milliseconds: 50));
        final isNowPlaying = await player.isPlaying() ?? false;
        if (!isNowPlaying) {
          debugPrint('Warning: Play command may not have taken effect');
        }
      } else {
        debugPrint('Video is already playing after seek');
      }

      // Clear the captured state after successful restoration
      _originalPlaybackState = null;
    } catch (e) {
      debugPrint('Failed to restore playback state: $e');
      // Clear state even on error to prevent stuck states
      _originalPlaybackState = null;
    }
  }

  void _seekTo(Duration position) async {
    await _executeWithRestriction(
      operationType: 'seek',
      operation: () async {
        // Capture original playback state before any debouncing
        await _captureOriginalPlaybackState();

        // Cancel any existing debounce timer
        _seekToDebounceTimer?.cancel();

        // Set up new debounce timer
        _seekToDebounceTimer = Timer(_debounceDuration, () async {
          await _performSeekOperation(
            targetPosition: position,
            onSuccess: () {
              widget.callbackOptions.onSeek?.call(position.inMilliseconds);
            },
          );
        });
      },
    );
  }

  void _seekForward() async {
    await _executeWithRestriction(
      operationType: 'seekForward',
      operation: () async {
        // Capture original playback state before any debouncing
        await _captureOriginalPlaybackState();

        // Cancel any existing debounce timer
        _seekForwardDebounceTimer?.cancel();

        // Set up new debounce timer
        _seekForwardDebounceTimer = Timer(_debounceDuration, () async {
          final currentPosition = player.value.position.inSeconds;
          final targetPosition = Duration(seconds: currentPosition + 10);

          await _performSeekOperation(
            targetPosition: targetPosition,
            onSuccess: () {
              widget.callbackOptions.onSeekForward?.call();
            },
          );
        });
      },
    );
  }

  void _seekBackward() async {
    await _executeWithRestriction(
      operationType: 'seekBackward',
      operation: () async {
        // Capture original playback state before any debouncing
        await _captureOriginalPlaybackState();

        // Cancel any existing debounce timer
        _seekBackwardDebounceTimer?.cancel();

        // Set up new debounce timer
        _seekBackwardDebounceTimer = Timer(_debounceDuration, () async {
          final currentPosition = player.value.position.inSeconds;
          final targetPosition =
              Duration(seconds: math.max(0, currentPosition - 10));

          await _performSeekOperation(
            targetPosition: targetPosition,
            onSuccess: () {
              widget.callbackOptions.onSeekBackward?.call();
            },
          );
        });
      },
    );
  }

  /// Centralized seek operation with robust error handling and timeout protection
  Future<void> _performSeekOperation({
    required Duration targetPosition,
    VoidCallback? onSuccess,
  }) async {
    if (_isDisposed || !player.value.isInitialized) {
      return;
    }

    // Validate target position
    final clampedPosition = Duration(
      milliseconds: targetPosition.inMilliseconds.clamp(
        0,
        _duration.inMilliseconds,
      ),
    );

    try {
      // Set loading state
      if (mounted) {
        setState(() {
          _isLoading = true;
        });
      }

      // Set up loading timeout as a safety net
      _loadingTimeoutTimer?.cancel();
      _loadingTimeoutTimer = Timer(const Duration(seconds: 10), () {
        if (mounted && !_isDisposed && _isLoading) {
          debugPrint('Loading timeout reached, forcing loading state reset');
          setState(() {
            _isLoading = false;
          });
        }
      });

      // Pause player before seeking (state is already captured)
      await player.pause().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          throw TimeoutException(
              'Pause operation timed out', const Duration(seconds: 2));
        },
      );

      // Perform seek operation with timeout
      await player.seekTo(clampedPosition).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException(
              'Seek operation timed out', const Duration(seconds: 5));
        },
      );

      // Update position immediately for UI responsiveness
      if (mounted) {
        setState(() {
          _currentPos = clampedPosition;
          _seekPos = 0;
        });
      }

      // Add a brief delay before state restoration to ensure seek operation completes
      // This prevents timing conflicts and ensures optimal performance
      await Future.delayed(const Duration(milliseconds: 100));

      // Restore original playback state
      await _restoreOriginalPlaybackState();

      // Cancel loading timeout timer since operation completed successfully
      _loadingTimeoutTimer?.cancel();

      // Reset loading state with a slight delay to ensure smooth transition
      Timer(const Duration(milliseconds: 500), () {
        if (mounted && !_isDisposed) {
          setState(() {
            _isLoading = false;
          });
        }
      });

      // Call success callback
      onSuccess?.call();
    } catch (e) {
      // Handle errors gracefully
      debugPrint('Seek operation failed: $e');

      // Cancel loading timeout timer
      _loadingTimeoutTimer?.cancel();

      // Reset loading state on error
      if (mounted && !_isDisposed) {
        setState(() {
          _isLoading = false;
        });
      }

      // Try to restore original playback state even on error
      try {
        // Add the same delay for consistency
        await Future.delayed(const Duration(milliseconds: 100));
        await _restoreOriginalPlaybackState();
      } catch (restoreError) {
        debugPrint(
            'Failed to restore playback state after seek error: $restoreError');
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    _isDisposed = true;
    player.removeListener(_listen);
    _hideTimer?.cancel();
    _statelessTimer?.cancel();

    // Cancel all debounce timers
    _playPauseDebounceTimer?.cancel();
    _seekForwardDebounceTimer?.cancel();
    _seekBackwardDebounceTimer?.cancel();
    _doubleTapDebounceTimer?.cancel();
    _seekToDebounceTimer?.cancel();

    // Cancel loading timeout timer
    _loadingTimeoutTimer?.cancel();

    ScreenBrightness().resetApplicationScreenBrightness();
  }

  void _onDoubleTap(TapDownDetails details) {
    // Cancel any existing debounce timer
    _doubleTapDebounceTimer?.cancel();

    // Set up new debounce timer
    _doubleTapDebounceTimer = Timer(_debounceDuration, () {
      if (widget.controlsOptions.doubleTapToSeek) {
        if (details.localPosition.dx > widget.viewSize.width / 2) {
          _seekForward();
        } else {
          _seekBackward();
        }
      }
    });
  }

  void onVerticalDragStartFun(DragStartDetails d) {
    _dragLeft = false;
    _dragRight = false;

    if (d.localPosition.dx >
        (widget.viewSize.width / 3 + (widget.viewSize.width / 3))) {
      // right, volume
      if (widget.controlsOptions.enableVolumeSlider) {
        _dragRight = true;
        double volume = _volume ?? (player.value.volume / 100).toDouble();
        setState(() {
          _slidingValue = volume;
          _volume = volume;
          _valController.add(volume);
        });
      }
    } else if (d.localPosition.dx < widget.viewSize.width / 3) {
      // left, brightness
      if (widget.controlsOptions.enableBrightnessSlider) {
        _dragLeft = true;
        ScreenBrightness().current.then((v) {
          setState(() {
            _slidingValue = v;
            _brightness = v;
            _valController.add(v);
          });
        });
      }
    }

    _statelessTimer?.cancel();
    _statelessTimer = Timer(const Duration(milliseconds: 2000), () {
      setState(() {});
    });
  }

  void onVerticalDragUpdateFun(DragUpdateDetails d) {
    double delta = d.primaryDelta! / widget.viewSize.height;
    delta = -delta.clamp(-1.0, 1.0);
    if (_dragRight == true) {
      var volume = _volume ?? 1;
      volume += delta;
      volume = volume.clamp(0.0, 1.0);
      player.setVolume((volume * 100).toInt());
      setState(() {
        _slidingValue = volume;
        _volume = volume;
        _valController.add(volume);
      });
    } else if (_dragLeft == true) {
      var brightness = _brightness;
      if (brightness != null) {
        brightness += delta;
        brightness = brightness.clamp(0.0, 1.0);
        _brightness = brightness;
        ScreenBrightness().setScreenBrightness(brightness);
        setState(() {
          _slidingValue = brightness;
          _valController.add(brightness!);
        });
      }
    }
  }

  void onVerticalDragEndFun(DragEndDetails e) {
    _slidingValue = null;
    _brightness = null;
    _statelessTimer?.cancel();
    setState(() {});
  }

  Widget _buildBufferingOverlay() {
    final bufferPercent = widget.player.value.bufferPercent;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.3),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.themeOptions.customLoadingWidget ??
                  SizedBox(
                    height: 50,
                    width: 50,
                    child: CircularProgressIndicator(
                      color: widget.themeOptions.loadingColor ??
                          Colors.greenAccent,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
              const SizedBox(height: 16),
              if (_isBuffering)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Buffering...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (bufferPercent > 0 && bufferPercent < 100) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${bufferPercent.toInt()}%',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
        child: Stack(
      fit: StackFit.expand,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          reverseDuration: const Duration(milliseconds: 400),
          child: !_hideStuff
              ? Stack(
                  key: const ValueKey<int>(0),
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTap: _cancelAndRestartTimer,
                      onDoubleTapDown: _onDoubleTap,
                      onVerticalDragStart: onVerticalDragStartFun,
                      onVerticalDragUpdate: onVerticalDragUpdateFun,
                      onVerticalDragEnd: onVerticalDragEndFun,
                      onHorizontalDragStart: (details) {},
                      child: Container(
                        color: Colors.transparent,
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                if (widget.controlsOptions.showBackbutton)
                                  // Back Button
                                  SizedBox(
                                    height: 50,
                                    width: 50,
                                    child: InkWell(
                                      onTap: () {
                                        widget.callbackOptions.onBackPressed
                                            ?.call();
                                      },
                                      child: Card(
                                        color: getIconsBackgroundColor(),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(10)),
                                        child: widget.themeOptions.backIcon ??
                                            const Icon(
                                              Icons.arrow_back_ios_new_rounded,
                                              color: Colors.white,
                                            ),
                                      ),
                                    ),
                                  ),
                                // Title and Subtitle Display
                                if (widget.title != null ||
                                    widget.subtitle != null)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (widget.title != null)
                                            Text(
                                              widget.title!,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (widget.subtitle != null)
                                            Text(
                                              widget.subtitle!,
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 14,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                const Spacer(),
                                // Custom Buttons
                                ..._customActionButtons.map(
                                  (e) => SizedBox(
                                    height: 50,
                                    width: 50,
                                    child: InkWell(
                                      onTap: () {
                                        if (e.onPressed != null) {
                                          e.onPressed!.call();
                                        }
                                      },
                                      onDoubleTap: () {
                                        if (e.onDoubleTap != null) {
                                          e.onDoubleTap!.call();
                                        }
                                      },
                                      onLongPress: () {
                                        if (e.onLongPress != null) {
                                          e.onLongPress!.call();
                                        }
                                      },
                                      child: Card(
                                        color: getIconsBackgroundColor(),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(10)),
                                        child: e.icon,
                                      ),
                                    ),
                                  ),
                                ),
                                // Mute/Unmute
                                if (widget.controlsOptions.showMute)
                                  SizedBox(
                                    height: 50,
                                    width: 50,
                                    child: InkWell(
                                      onTap: () {
                                        setState(() {
                                          _startHideTimer();
                                          if (player.value.volume > 0) {
                                            player.setVolume(0);
                                          } else {
                                            _volume = 100;
                                            player.setVolume(100);
                                          }
                                        });

                                        widget.callbackOptions.onMutePressed
                                            ?.call();
                                      },
                                      child: Card(
                                        color: getIconsBackgroundColor(),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(10)),
                                        child: player.value.volume > 0
                                            ? widget.themeOptions.muteIcon ??
                                                const Icon(
                                                  Icons.volume_up_rounded,
                                                  color: Colors.white,
                                                )
                                            : widget.themeOptions.unmuteIcon ??
                                                const Icon(
                                                  Icons.volume_off_rounded,
                                                  color: Colors.white,
                                                ),
                                      ),
                                    ),
                                  ),
                                // Settings/Menu
                                if (widget.controlsOptions.showMenu)
                                  SizedBox(
                                    height: 50,
                                    width: 50,
                                    child: InkWell(
                                      onTap: () {
                                        _startHideTimer();
                                        showOptions(context);

                                        widget.callbackOptions.onMenuPressed
                                            ?.call();
                                      },
                                      child: Card(
                                        color: getIconsBackgroundColor(),
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(10)),
                                        child: widget.themeOptions.menuIcon ??
                                            const Icon(
                                              Icons.settings_rounded,
                                              color: Colors.white,
                                            ),
                                      ),
                                    ),
                                  )
                              ],
                            )
                          ],
                        ),
                      ),
                    ),
                    if (widget.controlsOptions.showBottomBar)
                      _bottomBar(context),
                  ],
                )
              : GestureDetector(
                  onTap: _cancelAndRestartTimer,
                  onDoubleTapDown: _onDoubleTap,
                  onVerticalDragStart: onVerticalDragStartFun,
                  onVerticalDragUpdate: onVerticalDragUpdateFun,
                  onVerticalDragEnd: onVerticalDragEndFun,
                  onHorizontalDragStart: (details) {},
                  child: Container(
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        Positioned.fill(
                            child: (_slidingValue != null)
                                ? IgnorePointer(
                                    child: _brightness != null
                                        ? _VideoControlsSliderToast(
                                            _brightness!,
                                            1,
                                            _valController.stream,
                                            widget.themeOptions
                                                    .brightnessSlidertheme ??
                                                ModernPlayerToastSliderThemeOption(
                                                    sliderColor: Colors.blue),
                                            widget.themeOptions
                                                    .volumeSlidertheme ??
                                                ModernPlayerToastSliderThemeOption(
                                                    sliderColor: Colors.blue))
                                        : _VideoControlsSliderToast(
                                            _volume!,
                                            0,
                                            _valController.stream,
                                            widget.themeOptions
                                                    .brightnessSlidertheme ??
                                                ModernPlayerToastSliderThemeOption(
                                                    sliderColor: Colors.blue),
                                            widget.themeOptions
                                                    .volumeSlidertheme ??
                                                ModernPlayerToastSliderThemeOption(
                                                    sliderColor: Colors.blue)),
                                  )
                                : const SizedBox.shrink())
                      ],
                    ),
                  ),
                ),
        ),
        // Initial loading indicator
        // if (_isLoading)
        //   Positioned.fill(
        //     child: Center(
        //       child: widget.themeOptions.customLoadingWidget ??
        //           SizedBox(
        //             height: 50,
        //             width: 50,
        //             child: CircularProgressIndicator(
        //               color: widget.themeOptions.loadingColor ??
        //                   Colors.greenAccent,
        //               strokeCap: StrokeCap.round,
        //             ),
        //           ),
        //     ),
        //   ),
        // Buffering overlay - shows when video is initialized but buffering
        if (_isLoading || _isBuffering) _buildBufferingOverlay(),
      ],
    ));
  }

  Widget _bottomBar(BuildContext context) {
    int duration = _duration.inSeconds;

    int currentValue = _seekPos > 0 ? _seekPos : _currentPos.inSeconds;
    currentValue = min(currentValue, duration);
    currentValue = max(currentValue, 0);

    Duration remaining = _duration - _currentPos;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 10,
      child: Container(
        height: widget.controlsOptions.durationAboveSlider ? 68 : 50,
        decoration: BoxDecoration(
            color: getIconsBackgroundColor(),
            borderRadius: BorderRadius.circular(15)),
        margin: const EdgeInsets.symmetric(horizontal: 15),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            //Duration above seekbar
            if (widget.controlsOptions.durationAboveSlider)
              SizedBox(
                height: 20,
                child: FittedBox(
                  fit: BoxFit.fitHeight,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 55),
                    child: Text(
                      "${getFormattedDuration(_seekPos > 0 ? Duration(seconds: _seekPos) : _currentPos)}/${getFormattedDuration(Duration(seconds: duration))}",
                      style: widget.themeOptions.progressSliderTheme
                              ?.progressTextStyle ??
                          const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),

            Row(
              children: [
                //Backward Seek
                if (widget.controlsOptions.showBottomBarSeekIcons)
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      onPressed: _isSeekBackwardOperating
                          ? null
                          : () {
                              _startHideTimer();
                              _seekBackward();
                            },
                      icon: const Icon(
                        Icons.replay_10_rounded,
                        size: 20,
                      ),
                      color: _isSeekBackwardOperating
                          ? Colors.white54
                          : Colors.white,
                    ),
                  ),
                SizedBox(
                  width: 40,
                  child: GestureDetector(
                    onTap: _isPlayPauseOperating
                        ? null
                        : () {
                            _startHideTimer();
                            _playOrPause();
                          },
                    child: Icon(
                      player.value.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 36,
                      color:
                          _isPlayPauseOperating ? Colors.white54 : Colors.white,
                    ),
                  ),
                ),
                //Forward Seek
                if (widget.controlsOptions.showBottomBarSeekIcons)
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      onPressed: _isSeekForwardOperating
                          ? null
                          : () {
                              _startHideTimer();
                              _seekForward();
                            },
                      icon: const Icon(
                        Icons.forward_10_rounded,
                        size: 20,
                      ),
                      color: _isSeekForwardOperating
                          ? Colors.white54
                          : Colors.white,
                    ),
                  ),
                const SizedBox(
                  width: 5,
                ),
                if (!widget.controlsOptions.durationAboveSlider)
                  Text(
                    getFormattedDuration(_seekPos > 0
                        ? Duration(seconds: _seekPos)
                        : _currentPos),
                    style: widget.themeOptions.progressSliderTheme
                            ?.progressTextStyle ??
                        const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                const SizedBox(
                  width: 10,
                ),
                Expanded(
                    child: SliderTheme(
                  data: SliderThemeData(
                      trackShape: VideoSliderTrackShape(),
                      activeTrackColor: widget.themeOptions.progressSliderTheme
                              ?.activeSliderColor ??
                          Colors.greenAccent,
                      secondaryActiveTrackColor: widget.themeOptions
                              .progressSliderTheme?.bufferSliderColor ??
                          Colors.white,
                      thumbColor:
                          widget.themeOptions.progressSliderTheme?.thumbColor ??
                              Colors.white,
                      inactiveTrackColor: widget.themeOptions
                              .progressSliderTheme?.inactiveSliderColor ??
                          Colors.white60,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7, pressedElevation: 10)),
                  child: Slider(
                    value: currentValue.toDouble(),
                    min: 0,
                    max: duration.toDouble(),
                    onChanged: _isSeekOperating
                        ? null
                        : (value) {
                            _startHideTimer();
                            setState(() {
                              _seekPos = value.toInt();
                            });
                          },
                    onChangeEnd: _isSeekOperating
                        ? null
                        : (value) {
                            _seekTo(Duration(seconds: value.toInt()));
                          },
                  ),
                )),
                const SizedBox(
                  width: 10,
                ),
                if (!widget.controlsOptions.durationAboveSlider)
                  Text(
                    "-${getFormattedDuration(_seekPos > 0 ? Duration(seconds: duration - _seekPos) : remaining)}",
                    style: widget.themeOptions.progressSliderTheme
                            ?.progressTextStyle ??
                        const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                const SizedBox(
                  width: 5,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void showOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: getMenuBackgroundColor(),
      constraints: const BoxConstraints(maxWidth: 400),
      builder: (context) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  ModernPlayerMenus().showQualityOptions(context,
                      menuColor: getMenuBackgroundColor(),
                      currentData: _currentVideoData,
                      allData: widget.videos,
                      onChangedQuality: _changeVideoQuality);
                },
                child: Row(
                  children: [
                    const Icon(
                      Icons.settings_outlined,
                      color: Colors.white,
                    ),
                    const SizedBox(
                      width: 20,
                    ),
                    Text(
                      "${translationOptions.qualityHeaderText ?? "Quality"}  ◉  ",
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    Text(
                      _currentVideoData.label,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 16),
                    )
                  ],
                ),
              ),
              const SizedBox(
                height: 30,
              ),
              GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  ModernPlayerMenus().showPlabackSpeedOptions(context,
                      menuColor: getMenuBackgroundColor(),
                      text: translationOptions.defaultPlaybackSpeedText ??
                          "Normal",
                      currentSpeed: player.value.playbackSpeed,
                      allSpeeds: _playbackSpeeds, onChnagedSpeed: (speed) {
                    player.setPlaybackSpeed(speed);
                    widget.callbackOptions.onChangedPlaybackSpeed?.call(speed);
                  });
                },
                child: Row(
                  children: [
                    const Icon(
                      Icons.speed_rounded,
                      color: Colors.white,
                    ),
                    const SizedBox(
                      width: 20,
                    ),
                    Text(
                      "${translationOptions.playbackSpeedText ?? "Plaback speed"}  ◉  ",
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    Text(
                      player.value.playbackSpeed == 1
                          ? translationOptions.defaultPlaybackSpeedText ??
                              "Normal"
                          : "${player.value.playbackSpeed.toStringAsFixed(2)}x",
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 16),
                    )
                  ],
                ),
              ),
              const SizedBox(
                height: 30,
              ),
              _subtitleRowWidget(context),
              const SizedBox(
                height: 30,
              ),
              _audioRowWidget(context),
              const SizedBox(
                height: 10,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subtitleRowWidget(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (_subtitleTracks != null) {
          if (_subtitleTracks!.entries.isNotEmpty) {
            Navigator.pop(context);
            ModernPlayerMenus().showSubtitleOptions(context,
                menuColor: getMenuBackgroundColor(),
                activeTrack: player.value.activeSpuTrack,
                allTracks: _subtitleTracks!,
                onChangedSubtitle: _changeSubtitleTrack);
          }
        }
      },
      child: _subtitleTracks != null
          ? _subtitleTracks!.entries.isNotEmpty
              ? Row(
                  children: [
                    const Icon(
                      Icons.closed_caption_outlined,
                      color: Colors.white,
                    ),
                    const SizedBox(
                      width: 20,
                    ),
                    Text(
                      "${translationOptions.subtitleText ?? "Subtitles"}  ◉  ",
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    Text(
                      _subtitleTracks!.entries.isNotEmpty
                          ? _subtitleTracks![player.value.activeSpuTrack] ??
                              translationOptions.noneSubtitleText ??
                              "None"
                          : translationOptions.unavailableSubtitleText ??
                              "Unavailable",
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 16),
                    )
                  ],
                )
              : Row(
                  children: [
                    const Icon(
                      Icons.closed_caption_outlined,
                      color: Colors.white38,
                    ),
                    const SizedBox(
                      width: 20,
                    ),
                    Text(
                      "${translationOptions.subtitleText ?? "Subtitles"}  ◉  ",
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 16),
                    ),
                    Text(
                      translationOptions.unavailableSubtitleText ??
                          "Unavailable",
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 16),
                    )
                  ],
                )
          : Row(
              children: [
                const Icon(
                  Icons.closed_caption_outlined,
                  color: Colors.white38,
                ),
                const SizedBox(
                  width: 20,
                ),
                Text(
                  "${translationOptions.subtitleText ?? "Subtitles"}  ◉  ",
                  style: const TextStyle(color: Colors.white38, fontSize: 16),
                ),
                Text(
                  translationOptions.unavailableSubtitleText ?? "Unavailable",
                  style: const TextStyle(color: Colors.white38, fontSize: 16),
                )
              ],
            ),
    );
  }

  Widget _audioRowWidget(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (_audioTracks != null) {
          if (_audioTracks![player.value.activeAudioTrack] != null) {
            Navigator.pop(context);
            ModernPlayerMenus().showAudioOptions(context,
                menuColor: getMenuBackgroundColor(),
                activeTrack: player.value.activeAudioTrack,
                allTracks: _audioTracks!,
                onChangedAudio: _changeAudioTrack);
          }
        }
      },
      child: _audioTracks![player.value.activeAudioTrack] != null
          ? Row(
              children: [
                const Icon(
                  Icons.speaker_group_outlined,
                  color: Colors.white,
                ),
                const SizedBox(
                  width: 20,
                ),
                Text(
                  "${translationOptions.audioHeaderText ?? "Audio"}  ◉  ",
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                Text(
                  _audioTracks == null
                      ? translationOptions.loadingAudioText ?? "Loading"
                      : _audioTracks![player.value.activeAudioTrack]!,
                  style: const TextStyle(color: Colors.white60, fontSize: 16),
                )
              ],
            )
          : Row(
              children: [
                const Icon(
                  Icons.closed_caption_outlined,
                  color: Colors.white38,
                ),
                const SizedBox(
                  width: 20,
                ),
                Text(
                  "${translationOptions.audioHeaderText ?? "Audio"}  ◉  ",
                  style: const TextStyle(color: Colors.white38, fontSize: 16),
                ),
                Text(
                  translationOptions.unavailableAudioText ?? "Default",
                  style: const TextStyle(color: Colors.white38, fontSize: 16),
                )
              ],
            ),
    );
  }

  Color getMenuBackgroundColor() {
    return widget.themeOptions.menuBackgroundColor ??
        const Color.fromARGB(255, 20, 20, 20);
  }

  Color getIconsBackgroundColor() {
    Color? color =
        widget.themeOptions.backgroundColor ?? Colors.black.withOpacity(.75);
    return color;
  }
}

class VideoSliderTrackShape extends RoundedRectSliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight!) / 2;
    final trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}

class _VideoControlsSliderToast extends StatefulWidget {
  final Stream<double> emitter;
  final double initial;

  // type 0 volume
  // type 1 screen brightness
  final int type;
  final ModernPlayerToastSliderThemeOption volumeSliderTheme;
  final ModernPlayerToastSliderThemeOption brightnessSliderTheme;

  const _VideoControlsSliderToast(this.initial, this.type, this.emitter,
      this.brightnessSliderTheme, this.volumeSliderTheme);

  @override
  _VideoControlsSliderToastState createState() =>
      _VideoControlsSliderToastState();
}

class _VideoControlsSliderToastState extends State<_VideoControlsSliderToast> {
  double value = 0;
  StreamSubscription? subs;

  @override
  void initState() {
    super.initState();
    value = widget.initial;
    subs = widget.emitter.listen((v) {
      setState(() {
        value = v;
      });
    });
  }

  @override
  void dispose() {
    super.dispose();
    subs?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;

    if (type == 0) {
      // Volume
      IconData iconData;
      if (value <= 0) {
        iconData = widget.volumeSliderTheme.unfilledIcon ?? Icons.volume_mute;
      } else if (value < 0.5) {
        iconData = widget.volumeSliderTheme.halfFilledIcon ?? Icons.volume_down;
      } else {
        iconData = widget.volumeSliderTheme.filledIcon ?? Icons.volume_up;
      }

      return Align(
        alignment: const Alignment(0, -0.4),
        child: Card(
          color: widget.volumeSliderTheme.backgroundColor ??
              Colors.black.withOpacity(.5),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  iconData,
                  color: widget.volumeSliderTheme.iconColor ?? Colors.white,
                ),
                const SizedBox(
                  width: 4,
                ),
                SizedBox(
                  width: 100,
                  height: 1.5,
                  child: LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white60,
                    valueColor: AlwaysStoppedAnimation(
                        widget.volumeSliderTheme.sliderColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      // Brightness
      IconData iconData;
      if (value <= 0) {
        iconData =
            widget.brightnessSliderTheme.unfilledIcon ?? Icons.brightness_low;
      } else if (value < 0.5) {
        iconData = widget.brightnessSliderTheme.halfFilledIcon ??
            Icons.brightness_medium;
      } else {
        iconData =
            widget.brightnessSliderTheme.filledIcon ?? Icons.brightness_high;
      }

      return Align(
        alignment: const Alignment(0, -0.4),
        child: Card(
          color: widget.brightnessSliderTheme.backgroundColor ??
              Colors.black.withOpacity(.5),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  iconData,
                  color: widget.brightnessSliderTheme.iconColor ?? Colors.white,
                ),
                const SizedBox(
                  width: 4,
                ),
                SizedBox(
                  width: 100,
                  height: 1.5,
                  child: LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white60,
                    valueColor: AlwaysStoppedAnimation(
                        widget.brightnessSliderTheme.sliderColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
  }
}
