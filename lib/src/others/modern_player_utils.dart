import 'package:modern_player/modern_player.dart';

String getFormattedDuration(Duration duration) {
  return "${duration.inHours > 0 ? "${(duration.inHours % 24).toString().padLeft(2, '0')}:" : ""}${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}";
}

/// For getting initial quality for youtube player
ModernPlayerVideoData getInitialQualityYoutube(
    {required List<ModernPlayerVideoData> videos, int? initialQulaity}) {
  List<ModernPlayerVideoData> initialVideoDatas = videos
      .where((element) => element.label == ("${initialQulaity.toString()}p"))
      .toList();

  ModernPlayerVideoData videoData =
      initialVideoDatas.isEmpty ? videos.first : initialVideoDatas.first;

  return videoData;
}
