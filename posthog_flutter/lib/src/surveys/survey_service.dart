import 'package:flutter/material.dart';
// ignore: unnecessary_import
import 'package:meta/meta.dart';

import '../util/logging.dart';
import '../posthog_observer.dart';
import 'models/posthog_display_survey.dart';
import 'models/survey_callbacks.dart';
import 'models/survey_appearance.dart';
import 'widgets/survey_bottom_sheet.dart';

/// A service that manages displaying surveys.
///
/// By default this service relies on [PosthogObserver] to supply the
/// [BuildContext] needed for the modal bottom sheet. Apps that do not use
/// [PosthogObserver] can instead register a custom provider via
/// [setContextProvider] (wired up automatically from
/// [PostHogConfig.surveyContextProvider] during [Posthog.setup]).
class SurveyService {
  static final SurveyService _instance = SurveyService._internal();

  factory SurveyService() => _instance;

  SurveyService._internal();

  /// How long to wait between context-provider retries when the app is still
  /// booting and [_contextProvider] returns null.
  static const _retryInterval = Duration(milliseconds: 500);

  /// Maximum number of retry attempts before discarding a pending survey.
  /// At 500 ms per attempt this equals 30 seconds total.
  static const _maxRetries = 60;

  bool _isShowingSurvey = false;
  BuildContext? _currentSurveyContext;

  /// Optional user-supplied context provider, registered when the app does
  /// not use [PosthogObserver]. See [setContextProvider].
  BuildContext? Function()? _contextProvider;

  /// Tracks the current retry attempt for the boot-delay path so we can
  /// enforce the [_maxRetries] ceiling.
  int _retryCount = 0;

  /// Holds survey arguments that arrived while [_contextProvider] was still
  /// returning null (e.g. during app boot). Replayed once context is ready.
  _PendingSurvey? _pendingSurvey;

  /// Registers a custom context provider set from
  /// [PostHogConfig.surveyContextProvider].
  ///
  /// Called by [PosthogFlutterIO] during [Posthog.setup]. Allows apps that do
  /// not install [PosthogObserver] to still receive surveys by supplying their
  /// own [BuildContext] source (e.g. a [GlobalKey<NavigatorState>]).
  @internal
  void setContextProvider(BuildContext? Function() provider) {
    _contextProvider = provider;
  }

  /// Shows a survey using either the registered context provider or, as a
  /// fallback, [PosthogObserver]'s stored context.
  ///
  /// If the custom provider is set but currently returns null (app still
  /// booting), the survey is queued and retried every [_retryInterval] for
  /// up to [_maxRetries] attempts before being discarded.
  Future<void> showSurvey(
    PostHogDisplaySurvey survey,
    OnSurveyShown onShown,
    OnSurveyResponse onResponse,
    OnSurveyClosed onClosed,
  ) async {
    if (_isShowingSurvey) {
      printIfDebug('[PostHog] A survey is already being displayed');
      return;
    }

    // Prefer the user-supplied provider over PosthogObserver. This lets apps
    // opt out of PosthogObserver entirely for the surveys feature.
    if (_contextProvider != null) {
      final ctx = _contextProvider!();
      if (ctx != null && ctx.mounted) {
        return _showSurveyWithNavigator(survey, onShown, onResponse, onClosed, ctx);
      }
      // Context is null — app is likely still booting (e.g. showing a splash
      // screen or auth gate). Queue the survey and retry until context is
      // ready or the timeout is reached.
      _schedulePendingSurvey(survey, onShown, onResponse, onClosed);
      return;
    }

    // Fallback: legacy path for apps that installed PosthogObserver.
    if (PosthogObserver.currentContext != null) {
      printIfDebug('[PostHog] Using PosthogObserver context for survey');
      return _showSurveyWithNavigator(
        survey,
        onShown,
        onResponse,
        onClosed,
        PosthogObserver.currentContext!,
      );
    }

    printIfDebug(
      '[PostHog] Cannot show survey: No valid context found. '
      'Either install PosthogObserver in your navigatorObservers, or set '
      'PostHogConfig.surveyContextProvider before calling Posthog().setup().',
    );
  }

  /// Stores [survey] as pending and begins the retry loop.
  ///
  /// Called when [_contextProvider] returns null, which happens when the app
  /// is still initializing. The loop re-checks the provider every
  /// [_retryInterval] until a mounted context is available or [_maxRetries]
  /// is exhausted.
  void _schedulePendingSurvey(
    PostHogDisplaySurvey survey,
    OnSurveyShown onShown,
    OnSurveyResponse onResponse,
    OnSurveyClosed onClosed,
  ) {
    _pendingSurvey = _PendingSurvey(survey, onShown, onResponse, onClosed);
    _retryCount = 0;
    _retryNext();
  }

  /// Single step of the retry loop; reschedules itself via [Future.delayed]
  /// until context is available, the timeout is reached, or the pending
  /// survey is cleared (e.g. by [hideSurvey]).
  void _retryNext() {
    if (_pendingSurvey == null) return;
    if (_retryCount >= _maxRetries) {
      printIfDebug(
        '[PostHog] Cannot show survey: timed out waiting for context after '
        '${_retryInterval.inMilliseconds * _maxRetries}ms. Make sure '
        'PostHogConfig.surveyContextProvider returns a mounted context.',
      );
      _pendingSurvey = null;
      _retryCount = 0;
      return;
    }
    _retryCount++;
    Future.delayed(_retryInterval, () {
      final pending = _pendingSurvey;
      if (pending == null || _isShowingSurvey) return;
      final ctx = _contextProvider?.call();
      if (ctx != null && ctx.mounted) {
        _pendingSurvey = null;
        _retryCount = 0;
        _showSurveyWithNavigator(
          pending.survey,
          pending.onShown,
          pending.onResponse,
          pending.onClosed,
          ctx,
        );
      } else {
        _retryNext();
      }
    });
  }

  /// Shows a survey using a navigator context.
  Future<void> _showSurveyWithNavigator(
    PostHogDisplaySurvey survey,
    OnSurveyShown onShown,
    OnSurveyResponse onResponse,
    OnSurveyClosed onClosed,
    BuildContext context,
  ) async {
    _isShowingSurvey = true;
    _currentSurveyContext = context;
    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        builder: (context) =>
            _buildSurveyWidget(survey, onShown, onResponse, (s) {
          _isShowingSurvey = false;
          _currentSurveyContext = null;
          onClosed(s);
        }),
      );
    } catch (e) {
      printIfDebug('[PostHog] Error showing survey: $e');
      _isShowingSurvey = false;
      _currentSurveyContext = null;
    }
  }

  /// Builds the survey widget.
  Widget _buildSurveyWidget(
    PostHogDisplaySurvey survey,
    OnSurveyShown onShown,
    OnSurveyResponse onResponse,
    OnSurveyClosed onClosed,
  ) {
    return SurveyBottomSheet(
      survey: survey,
      onShown: onShown,
      onResponse: onResponse,
      onClosed: onClosed,
      appearance: SurveyAppearance.fromPostHog(survey.appearance),
    );
  }

  /// Hides any active survey and cancels any pending retry.
  ///
  /// The pending survey is cleared so it does not appear after the session
  /// has already been torn down (e.g. when [Posthog.close] is called).
  void hideSurvey() {
    // Cancel any survey queued by the boot-delay retry path so it does not
    // surface after the SDK session has been closed.
    _pendingSurvey = null;
    _retryCount = 0;

    final context = _currentSurveyContext;
    if (_isShowingSurvey && context != null) {
      // Use the stored context to properly dismiss the bottom sheet.
      Navigator.of(context).pop();
      _currentSurveyContext = null;
    }
    _isShowingSurvey = false;
  }
}

/// Captures the full argument set of a [SurveyService.showSurvey] call so it
/// can be replayed once a valid [BuildContext] becomes available during the
/// boot-delay retry loop.
class _PendingSurvey {
  final PostHogDisplaySurvey survey;
  final OnSurveyShown onShown;
  final OnSurveyResponse onResponse;
  final OnSurveyClosed onClosed;

  const _PendingSurvey(
    this.survey,
    this.onShown,
    this.onResponse,
    this.onClosed,
  );
}
