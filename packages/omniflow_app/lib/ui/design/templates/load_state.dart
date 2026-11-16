import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../banner.dart';
import '../icons.dart';
import '../skeleton.dart';
import '../tokens.dart';

/// Where a page's data is: still coming, failed, there but empty, or there.
enum OmniLoadStatus { loading, error, empty, data }

/// The loading, error and empty state a template draws for a screen, so the
/// screen writes only the data case. Build one from an [AsyncValue] with
/// [OmniLoad.of], from flags with [OmniLoad.flags], or name it directly.
@immutable
class OmniLoad {
  const OmniLoad.loading()
    : status = OmniLoadStatus.loading,
      message = null,
      onRetry = null;

  /// The data is there. [error] is a refresh that failed: the template
  /// keeps the data and puts an error banner with Try again above it.
  const OmniLoad.data({String? error, this.onRetry})
    : status = OmniLoadStatus.data,
      message = error;

  const OmniLoad.empty()
    : status = OmniLoadStatus.empty,
      message = null,
      onRetry = null;

  /// Nothing to show and the load failed. [message] is plain words, never
  /// raw exception text.
  const OmniLoad.error([this.message = defaultError, this.onRetry])
    : status = OmniLoadStatus.error;

  /// Reads an [AsyncValue]: a value (even while it refreshes) is data, or
  /// empty when [isEmpty] says so; an error with a cached value is data
  /// with an error banner; an error with none is [OmniLoadStatus.error].
  static OmniLoad of<T>(
    AsyncValue<T> value, {
    bool Function(T value)? isEmpty,
    VoidCallback? onRetry,
    String error = defaultError,
  }) {
    if (value.hasValue) {
      final v = value.value as T;
      final empty = isEmpty?.call(v) ?? false;
      if (value.hasError) {
        return empty
            ? OmniLoad.error(error, onRetry)
            : OmniLoad.data(error: error, onRetry: onRetry);
      }
      return empty ? const OmniLoad.empty() : const OmniLoad.data();
    }
    if (value.hasError) return OmniLoad.error(error, onRetry);
    return const OmniLoad.loading();
  }

  /// For a screen that keeps its own flags. [error] wins over [loading],
  /// and both win over [isEmpty].
  static OmniLoad flags({
    bool loading = false,
    String? error,
    bool isEmpty = false,
    VoidCallback? onRetry,
  }) {
    if (error != null) return OmniLoad.error(error, onRetry);
    if (loading) return const OmniLoad.loading();
    if (isEmpty) return const OmniLoad.empty();
    return const OmniLoad.data();
  }

  /// What an error says when the screen gives no words of its own.
  static const defaultError = 'OmniFlow did not answer.';

  final OmniLoadStatus status;

  /// The error, for [OmniLoadStatus.error], or a failed refresh on data.
  final String? message;
  final VoidCallback? onRetry;

  bool get isLoading => status == OmniLoadStatus.loading;
  bool get isError => status == OmniLoadStatus.error;
  bool get isEmpty => status == OmniLoadStatus.empty;
  bool get isData => status == OmniLoadStatus.data;
}

/// The loading shape a template shows.
enum OmniSkeleton {
  /// List rows ([OmniListSkeleton]).
  rows,

  /// A grid of tiles ([OmniTileGridSkeleton]).
  tiles,

  /// A hero card and rows ([OmniPageSkeleton]).
  page,
}

/// The one error banner of the templates: what happened and Try again.
class OmniErrorBanner extends StatelessWidget {
  const OmniErrorBanner(this.message, {super.key, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => OmniBanner.error(
    message,
    key: const ValueKey('omni-error'),
    actionLabel: onRetry == null ? null : 'Try again',
    onAction: onRetry,
  );
}

/// The widgets a template's scroll body shows for [state]: the skeleton,
/// the error (a full-page [OmniErrorState] when [fullPageError], else the
/// banner), the [empty] state, or [banners] then [data].
List<Widget> omniStateChildren(
  BuildContext context, {
  required OmniLoad state,
  required List<Widget> Function(BuildContext context) data,
  OmniSkeleton skeleton = OmniSkeleton.rows,
  int skeletonRows = 5,
  Widget? empty,
  bool fullPageError = false,
  List<Widget> banners = const [],
}) {
  switch (state.status) {
    case OmniLoadStatus.loading:
      return [
        switch (skeleton) {
          OmniSkeleton.rows => OmniListSkeleton(rows: skeletonRows),
          OmniSkeleton.tiles => const OmniTileGridSkeleton(),
          OmniSkeleton.page => OmniPageSkeleton(rows: skeletonRows),
        },
      ];
    case OmniLoadStatus.error:
      final message = state.message ?? OmniLoad.defaultError;
      return [
        if (fullPageError)
          OmniErrorState(message: message, onRetry: state.onRetry)
        else
          OmniErrorBanner(message, onRetry: state.onRetry),
      ];
    case OmniLoadStatus.empty:
      return [...banners, empty ?? omniDefaultEmpty];
    case OmniLoadStatus.data:
      return [
        if (state.message != null)
          OmniErrorBanner(state.message!, onRetry: state.onRetry),
        ...banners,
        ...data(context),
      ];
  }
}

/// A custom data body (a grid, a canvas, a reorderable list) with the
/// refresh error banner and [banners] pinned above it, screen padded.
Widget omniCustomBody(
  BuildContext context, {
  required OmniLoad state,
  required WidgetBuilder body,
  List<Widget> banners = const [],
}) {
  final top = [
    if (state.message != null)
      OmniErrorBanner(state.message!, onRetry: state.onRetry),
    ...banners,
  ];
  if (top.isEmpty) return body(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: OmniSpace.screenPadding,
        child: Column(mainAxisSize: MainAxisSize.min, children: top),
      ),
      Expanded(child: body(context)),
    ],
  );
}

/// The empty state a template shows when the screen gives none.
const omniDefaultEmpty = OmniEmptyState(
  icon: OmniIcons.info,
  title: 'Nothing here yet',
);

/// The padding of a template's scroll body: the screen padding on the
/// sides and [bottom] under the last row.
EdgeInsets omniBodyPadding(double bottom, {bool padded = true}) =>
    EdgeInsets.fromLTRB(
      padded ? OmniSpace.screen : 0,
      0,
      padded ? OmniSpace.screen : 0,
      bottom,
    );
