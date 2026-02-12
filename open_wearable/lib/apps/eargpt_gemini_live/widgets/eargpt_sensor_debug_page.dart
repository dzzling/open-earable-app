// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:open_wearable/apps/posture_tracker/model/attitude_tracker.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/eargpt_sensor_manager.dart'
    as eargpt;
import 'package:open_wearable/apps/eargpt_gemini_live/model/gemini_session_manager.dart';
import 'package:open_wearable/apps/eargpt_gemini_live/model/tools.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:lottie/lottie.dart';
import 'package:open_wearable/view_models/app_data_storage.dart';

class EargptSensorDebugPage extends StatefulWidget {
  final Sensor? ppgSensor;
  final Wearable? wearable;
  final AttitudeTracker attitudeTracker;
  final Sensor? skinTempSensor;

  const EargptSensorDebugPage({
    super.key,
    required this.ppgSensor,
    required this.skinTempSensor,
    this.wearable,
    required this.attitudeTracker,
  });

  @override
  State<EargptSensorDebugPage> createState() => _EargptSensorDebugPageState();
}

class _EargptSensorDebugPageState extends State<EargptSensorDebugPage>
    with TickerProviderStateMixin {
  late final AnimationController _animationController;
  late final LiveGenerativeModel model;
  late final eargpt.EarGPTSensorManager _sensorManager;
  late final GeminiSessionManager _sessionManager;
  late final EarGPTTools _tools;

  static const String _storageAppName = 'eargpt_gemini_live';
  static const String _heartRateStorageKey = 'latest_heart_rate';
  static const String _skinTempStorageKey = 'latest_skin_temperature';
  static const int _historyDays = 7;

  //============================================================================
  // BUTTON HANDLER
  //============================================================================

  void _handleButtonPressed() {
    if (mounted) {
      setState(() {
        if (_sessionManager.conversationActive) {
          _sessionManager.endConversation();
        } else {
          _sessionManager.startConversation();
        }
      });
    }
  }

  //============================================================================
  // INIT STATE
  //============================================================================

  @override
  void initState() {
    super.initState();

    // Initialize animation controller
    _animationController = AnimationController(vsync: this);

    // Initialize SensorManager
    _sensorManager = eargpt.EarGPTSensorManager(
      ppgSensor: widget.ppgSensor,
      skinTempSensor: widget.skinTempSensor,
      wearable: widget.wearable,
      attitudeTracker: widget.attitudeTracker,
      onHeartRateUpdate: (heartRate) {
        if (mounted) {
          setState(() {});
        }
      },
      onSkinTempUpdate: (skinTemp) {
        if (mounted) {
          setState(() {});
        }
      },
      onAttitudeChanged: () {
        // Handle attitude changes if needed
      },
    );

    // Initialize EarGPTTools
    _tools = EarGPTTools(sensorManager: _sensorManager);

    // Setup Gemini Live Generative Model
    model = FirebaseAI.googleAI().liveGenerativeModel(
      model: 'gemini-2.5-flash-native-audio-preview-12-2025',
      systemInstruction: Content.system(
          '''You are a personal health AI assistant integrated with OpenEarable smart earbuds. You have access to real-time biometric data from the user's ear-based sensors. Keep responses concise and relevant to the user's health and activity.
          Use the provided tools to get the user's health statistics.'''),
      tools: [
        Tool.functionDeclarations(EarGPTTools.getAllToolDeclarations()),
      ],
      liveGenerationConfig:
          LiveGenerationConfig(responseModalities: [ResponseModalities.audio]),
    );

    // Initialize GeminiSessionManager
    _sessionManager = GeminiSessionManager(
      model: model,
      toolExecutors: _tools.toolExecutors,
      onConversationStateChanged: () {
        if (mounted) setState(() {});
      },
      onRecordingStateChanged: () {
        if (mounted) {
          setState(() {
            _syncAnimationWithRecordingState();
          });
        }
      },
      onPersistVitals: _persistLatestVitals,
    );

    // Setup sensors and data streams asynchronously to ensure proper sequencing
    _initializeSensors();
  }

  /// Initialize sensors using SensorManager
  Future<void> _initializeSensors() async {
    if (!mounted) return;

    await _sensorManager.initialize(context);

    // Setup button listener after sensors are initialized
    _sensorManager.setupButtonListener(_handleButtonPressed);

    if (mounted) {
      setState(() {});
    }
  }

  //============================================================================
  // DATA PERSISTENCE
  //============================================================================

  Future<void> _persistLatestVitals() async {
    await _saveLatestHeartRate();
    await _saveLatestSkinTemperature();
  }

  /// For each vital, save the latest value along with a history of values within the cutoff period (e.g. last 7 days)
  /// [key] - The storage key for the vital
  /// [value] - The latest value to store
  /// [unit] - The unit of the value (e.g., 'bpm', 'celsius')
  /// [timestamp] - The timestamp of the value
  /// There will alway be only one latest value stored, together with a rolling history of values within the cutoff period
  /// There is no older history beyond the cutoff period
  Future<void> _saveLatestVital(
    String key,
    double? value,
    String unit,
  ) async {
    if (value == null) {
      logger.w("No cached $key to persist.");
      return;
    }

    final recordedAt = DateTime.now();
    final recordedMicros = recordedAt.microsecondsSinceEpoch;
    final cutoffMicros = recordedAt
        .subtract(Duration(days: _historyDays))
        .microsecondsSinceEpoch;

    try {
      final existing =
          await AppDataStorage.loadData(_storageAppName, key) ?? {};
      final historyDynamic = existing['history'] as List<dynamic>? ?? [];
      final history = historyDynamic.whereType<Map>().where((entry) {
        final ts = entry['recorded_at_epoch_micros'] as int?;
        return ts != null && ts >= cutoffMicros;
      }).toList();

      history.add({
        'value': value,
        'unit': unit,
        'recorded_at': recordedAt.toIso8601String(),
        'recorded_at_epoch_micros': recordedMicros,
      });

      final latest = history.last;

      await AppDataStorage.saveData(_storageAppName, key, {
        'latest': latest,
        'history': history,
      });
      logger.i("Persisted latest $key: $value $unit");
    } catch (e) {
      logger.w("Failed to persist $key: $e");
    }
  }

  // Save latest heart rate with history
  Future<void> _saveLatestHeartRate() async {
    await _saveLatestVital(
      _heartRateStorageKey,
      _sensorManager.cachedHeartRate,
      'bpm',
    );
  }

  // Save latest skin temperature with history
  Future<void> _saveLatestSkinTemperature() async {
    await _saveLatestVital(
      _skinTempStorageKey,
      _sensorManager.cachedSkinTemp,
      'celsius',
    );
  }

  //============================================================================
  // HANDLE ANIMATION STATE
  //============================================================================

  void _syncAnimationWithRecordingState() {
    if (_sessionManager.isRecording && _animationController.isAnimating) {
      _animationController.animateBack(0.0);
    } else if (!_sessionManager.isRecording &&
        !_animationController.isAnimating &&
        _sessionManager.conversationActive) {
      _animationController.forward();
      _animationController.repeat();
    } else if (!_sessionManager.conversationActive &&
        _animationController.isAnimating) {
      _animationController.stop();
      _animationController.reset();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _sensorManager.dispose();
    _sessionManager.dispose();
    super.dispose();
  }

  //============================================================================
  // BUILD WIDGET/UI
  //============================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("EarGPT Sensor Debug Page"),
      ),
      floatingActionButton: FloatingActionButton.large(
        foregroundColor:
            _sessionManager.conversationActive ? Colors.white : Colors.green,
        backgroundColor:
            _sessionManager.conversationActive ? Colors.red : Colors.white,
        onPressed: () {
          _sessionManager.conversationActive
              ? _sessionManager.endConversation()
              : _sessionManager.startConversation();
        },
        child: _sessionManager.conversationActive
            ? const Icon(Icons.stop_circle)
            : const Icon(Icons.play_circle),
      ),
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Column(
                  children: [
                    PlatformText(
                      "Heart Rate: ${_sensorManager.cachedHeartRate?.toStringAsFixed(1) ?? '--'} BPM\n"
                      "Skin Temp: ${_sensorManager.cachedSkinTemp?.toStringAsFixed(1) ?? '--'} °C",
                      style: Theme.of(context).textTheme.titleLarge,
                      softWrap: true,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 16),
                    FloatingActionButton.extended(
                      onPressed: () => {},
                      label: PlatformText(
                        "Session active: ${_sessionManager.conversationActive ? "Yes" : "No"}",
                      ),
                      foregroundColor: _sessionManager.conversationActive
                          ? Colors.white
                          : Colors.white,
                      backgroundColor: _sessionManager.conversationActive
                          ? Colors.red
                          : Colors.lightGreen,
                    ),
                    SizedBox(height: 16),
                    Lottie.asset(
                      'lib/apps/eargpt_gemini_live/assets/loading.json',
                      width: 200,
                      height: 200,
                      controller: _animationController,
                      onLoaded: (composition) {
                        // Configure the AnimationController with the duration of the
                        // Lottie file and sync with recording state.
                        _animationController.duration = composition.duration;
                        _syncAnimationWithRecordingState();
                      },
                    ),
                    SizedBox(height: 16),
                    FloatingActionButton.extended(
                      onPressed: () => {},
                      label: PlatformText(
                        _sessionManager.conversationActive
                            ? _sessionManager.isRecording
                                ? "Listening..."
                                : "Talking..."
                            : "Inactive",
                      ),
                      foregroundColor: _sessionManager.isRecording
                          ? Colors.white
                          : Colors.black,
                      backgroundColor: _sessionManager.isRecording
                          ? Colors.red
                          : Colors.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
