import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'music_library_service.dart';

/// Thrown when [MusicCropService.trim] is given a file it doesn't know
/// how to cut. Distinct from a generic [Exception] so callers can show
/// a message that actually explains what happened, instead of a
/// catch-all "something went wrong".
class UnsupportedAudioFormatException implements Exception {
  final String message;
  UnsupportedAudioFormatException(this.message);
  @override
  String toString() => message;
}

/// The result of [MusicCropScreen]: the source [track], the window the
/// person chose within it ([start] + [duration]), and the actual audio
/// [file] to upload — either a freshly trimmed clip, or the original
/// file untouched when the track was already short enough that no
/// cropping was needed.
///
/// [identifiedTitle]/[identifiedArtist] come from [AuddService] running
/// an audio-fingerprint match against the clip — when present, they
/// take priority over the (often missing or wrong) tag on [track],
/// same as the tag would over a raw filename. Null when AudD isn't
/// configured or didn't recognize the clip; callers fall back to
/// [track]'s own tag transparently via [displayTitle]/[displayLabel].
class CroppedMusicClip {
  final LibraryTrack track;
  final Duration start;
  final Duration duration;
  final File file;
  final String? identifiedTitle;
  final String? identifiedArtist;

  const CroppedMusicClip({
    required this.track,
    required this.start,
    required this.duration,
    required this.file,
    this.identifiedTitle,
    this.identifiedArtist,
  });

  /// True when the title/artist shown came from AudD's fingerprint
  /// match rather than the device's own file tags.
  bool get isIdentified => identifiedTitle != null;

  String get displayTitle => identifiedTitle ?? track.title;
  String? get displayArtist =>
      identifiedArtist ?? (identifiedTitle != null ? null : track.artist);

  /// "Song — Artist" if an artist is known, else just the title —
  /// mirrors [LibraryTrack.displayLabel] but preferring the AudD match.
  String get displayLabel => (displayArtist != null && displayArtist!.isNotEmpty)
      ? '$displayTitle — $displayArtist'
      : displayTitle;
}

class MusicCropService {
  MusicCropService._();

  static final MusicCropService instance = MusicCropService._();

  /// Cuts [duration] worth of audio out of the file at [sourcePath],
  /// starting at [start], and writes it to a new file in the temp
  /// directory.
  ///
  /// This is done entirely in Dart — no FFmpeg or other native binary
  /// — so it only supports the two formats that are actually trimmable
  /// without a real decoder/encoder pass:
  ///
  ///  * MP3: cut losslessly at frame boundaries. Every MPEG audio frame
  ///    decodes independently, so a valid clip can be built by simply
  ///    copying whole frames that overlap the requested window — no
  ///    re-encoding needed.
  ///  * WAV (PCM): cut at the byte level within the `data` chunk, since
  ///    it's uncompressed and every sample is addressable directly.
  ///
  /// Anything else (m4a/AAC, FLAC, OGG, ...) throws
  /// [UnsupportedAudioFormatException] rather than pretending to work.
  Future<File> trim({
    required String sourcePath,
    required Duration start,
    required Duration duration,
  }) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('Source audio file does not exist.');
    }

    final bytes = await sourceFile.readAsBytes();

    Uint8List trimmed;
    String outExtension;
    if (_looksLikeWav(bytes)) {
      trimmed = _trimWav(bytes, start, duration);
      outExtension = '.wav';
    } else if (_looksLikeMp3(bytes)) {
      trimmed = _trimMp3(bytes, start, duration);
      outExtension = '.mp3';
    } else {
      throw UnsupportedAudioFormatException(
        "This track's file type can't be cropped yet — only MP3 and WAV "
        'tracks support trimming right now.',
      );
    }

    final dir = await getTemporaryDirectory();
    final outPath =
        '${dir.path}/music_crop_${DateTime.now().millisecondsSinceEpoch}$outExtension';
    final outFile = File(outPath);
    await outFile.writeAsBytes(trimmed, flush: true);
    return outFile;
  }

  // ---------------------------------------------------------------------
  // Format sniffing
  // ---------------------------------------------------------------------

  bool _looksLikeWav(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x41 && // A
        bytes[10] == 0x56 && // V
        bytes[11] == 0x45; // E
  }

  bool _looksLikeMp3(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // ID3v2 tag up front.
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;
    // Bare frame sync (11 set bits) within the first few KB — some MP3s
    // have no ID3 tag at all, and a couple of junk bytes before the
    // first frame is common enough to be worth scanning past.
    final searchLimit = bytes.length < 4096 ? bytes.length - 1 : 4096;
    for (var i = 0; i < searchLimit; i++) {
      if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
        final layerBits = (bytes[i + 1] >> 1) & 0x3;
        final versionBits = (bytes[i + 1] >> 3) & 0x3;
        if (layerBits != 0 && versionBits != 1) return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------
  // WAV (PCM) trimming — direct byte-range cut of the `data` chunk.
  // ---------------------------------------------------------------------

  Uint8List _trimWav(Uint8List bytes, Duration start, Duration duration) {
    int? fmtOffset, fmtSize;
    int? dataOffset, dataSize;

    var pos = 12; // past "RIFF"<size>"WAVE"
    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
      final size = _readU32LE(bytes, pos + 4);
      final bodyStart = pos + 8;
      if (bodyStart + size > bytes.length) break;

      if (id == 'fmt ') {
        fmtOffset = bodyStart;
        fmtSize = size;
      } else if (id == 'data') {
        dataOffset = bodyStart;
        dataSize = size;
      }
      // Chunks are padded to an even number of bytes.
      pos = bodyStart + size + (size.isOdd ? 1 : 0);
    }

    if (fmtOffset == null || fmtSize == null || dataOffset == null || dataSize == null) {
      throw UnsupportedAudioFormatException(
        "Couldn't read this WAV file's audio data.",
      );
    }

    final channels = _readU16LE(bytes, fmtOffset + 2);
    final sampleRate = _readU32LE(bytes, fmtOffset + 4);
    final bitsPerSample = _readU16LE(bytes, fmtOffset + 14);
    final blockAlign =
        (channels * bitsPerSample / 8).round().clamp(1, 1 << 16);
    final byteRate = sampleRate * channels * (bitsPerSample / 8);

    if (byteRate <= 0) {
      throw UnsupportedAudioFormatException(
        "Couldn't read this WAV file's audio format.",
      );
    }

    int alignDown(int value) => value - (value % blockAlign);

    var startByte = alignDown((start.inMilliseconds / 1000 * byteRate).round());
    var lengthBytes =
        alignDown((duration.inMilliseconds / 1000 * byteRate).round());

    startByte = startByte.clamp(0, dataSize);
    lengthBytes = lengthBytes.clamp(0, dataSize - startByte);

    final clippedData =
        bytes.sublist(dataOffset + startByte, dataOffset + startByte + lengthBytes);
    final fmtChunk = bytes.sublist(fmtOffset - 8, fmtOffset + fmtSize);

    final riffSize = 4 + fmtChunk.length + 8 + clippedData.length;
    final out = BytesBuilder();
    out.add([0x52, 0x49, 0x46, 0x46]); // RIFF
    out.add(_u32LE(riffSize));
    out.add([0x57, 0x41, 0x56, 0x45]); // WAVE
    out.add(fmtChunk);
    out.add([0x64, 0x61, 0x74, 0x61]); // data
    out.add(_u32LE(clippedData.length));
    out.add(clippedData);
    return out.toBytes();
  }

  int _readU16LE(Uint8List b, int offset) => b[offset] | (b[offset + 1] << 8);

  int _readU32LE(Uint8List b, int offset) =>
      b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16) | (b[offset + 3] << 24);

  Uint8List _u32LE(int value) => Uint8List(4)
    ..[0] = value & 0xFF
    ..[1] = (value >> 8) & 0xFF
    ..[2] = (value >> 16) & 0xFF
    ..[3] = (value >> 24) & 0xFF;

  // ---------------------------------------------------------------------
  // MP3 trimming — lossless frame-boundary cut, no re-encoding.
  // ---------------------------------------------------------------------

  static const _bitrateTableV1 = {
    1: [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    2: [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    3: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  };
  static const _bitrateTableV2 = {
    1: [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    3: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  };
  static const _sampleRatesV1 = [44100, 48000, 32000];
  static const _sampleRatesV2 = [22050, 24000, 16000];
  static const _sampleRatesV25 = [11025, 12000, 8000];

  Uint8List _trimMp3(Uint8List bytes, Duration start, Duration duration) {
    var offset = 0;
    var end = bytes.length;

    // Strip a trailing ID3v1 tag ("TAG" + 125 bytes) if present, so it
    // doesn't get scanned as frame data.
    if (end >= 128 &&
        bytes[end - 128] == 0x54 &&
        bytes[end - 127] == 0x41 &&
        bytes[end - 126] == 0x47) {
      end -= 128;
    }

    // Skip a leading ID3v2 tag if present.
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      final flags = bytes[5];
      final size = ((bytes[6] & 0x7F) << 21) |
          ((bytes[7] & 0x7F) << 14) |
          ((bytes[8] & 0x7F) << 7) |
          (bytes[9] & 0x7F);
      offset = 10 + size;
      if (flags & 0x10 != 0) offset += 10; // footer present
    }

    final frames = <_Mp3Frame>[];
    var cursorMs = 0.0;
    var pos = offset;

    while (pos + 4 <= end) {
      if (bytes[pos] != 0xFF || (bytes[pos + 1] & 0xE0) != 0xE0) {
        pos++;
        continue;
      }
      final b1 = bytes[pos + 1];
      final b2 = bytes[pos + 2];

      final versionBits = (b1 >> 3) & 0x3;
      final layerBits = (b1 >> 1) & 0x3;
      if (versionBits == 1 || layerBits == 0) {
        pos++;
        continue; // reserved
      }
      final isMpeg1 = versionBits == 3;
      final layer = layerBits == 3 ? 1 : (layerBits == 2 ? 2 : 3);

      final bitrateIndex = (b2 >> 4) & 0xF;
      final sampleRateIndex = (b2 >> 2) & 0x3;
      final padding = (b2 >> 1) & 0x1;
      if (bitrateIndex == 0 || bitrateIndex == 15 || sampleRateIndex == 3) {
        pos++;
        continue;
      }

      final bitrateKbps = (isMpeg1 ? _bitrateTableV1 : _bitrateTableV2)[layer]![bitrateIndex];
      final sampleRate = isMpeg1
          ? _sampleRatesV1[sampleRateIndex]
          : (versionBits == 2 ? _sampleRatesV2[sampleRateIndex] : _sampleRatesV25[sampleRateIndex]);
      if (bitrateKbps == 0) {
        pos++;
        continue; // "free" bitrate — not worth supporting here
      }

      final bitrateBps = bitrateKbps * 1000;
      final frameLen = layer == 1
          ? (((12 * bitrateBps) ~/ sampleRate) + padding) * 4
          : (layer == 3 && !isMpeg1)
              ? (((72 * bitrateBps) ~/ sampleRate) + padding)
              : (((144 * bitrateBps) ~/ sampleRate) + padding);

      if (frameLen <= 0 || pos + frameLen > end) {
        pos++;
        continue;
      }

      final samplesPerFrame =
          layer == 1 ? 384 : (layer == 2 ? 1152 : (isMpeg1 ? 1152 : 576));
      final frameMs = samplesPerFrame / sampleRate * 1000;

      frames.add(_Mp3Frame(pos, frameLen, cursorMs, frameMs));
      cursorMs += frameMs;
      pos += frameLen;
    }

    if (frames.isEmpty) {
      throw UnsupportedAudioFormatException(
        "Couldn't read this MP3's audio frames — it may be corrupted or "
        'use an unsupported encoding.',
      );
    }

    final startMs = start.inMilliseconds.toDouble();
    final endMs = startMs + duration.inMilliseconds.toDouble();

    var selected = frames
        .where((f) => f.startMs + f.durationMs > startMs && f.startMs < endMs)
        .toList();

    if (selected.isEmpty) {
      // The requested window landed past the last decodable frame
      // (rounding at the very end of the track) — fall back to
      // whatever's left rather than returning an empty file.
      selected = [frames.last];
    }

    final builder = BytesBuilder(copy: false);
    for (final f in selected) {
      builder.add(bytes.sublist(f.offset, f.offset + f.length));
    }
    return builder.toBytes();
  }
}

class _Mp3Frame {
  final int offset;
  final int length;
  final double startMs;
  final double durationMs;
  _Mp3Frame(this.offset, this.length, this.startMs, this.durationMs);
}
