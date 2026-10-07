// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';

import '../primitives/errors.dart';
import '../primitives/event_notifier.dart';
import 'catalog.dart';
import 'common.dart';
import 'component_model.dart';
import 'contexts.dart';
import 'data_model.dart';
import 'messages.dart';

/// The state model for a single UI surface.
class SurfaceModel<T extends ComponentApi> {
  final String id;

  /// The surface's default catalog, from the `catalogId` on `createSurface`.
  ///
  /// Null when the surface names none, which v1.0 allows: every component
  /// and function call on such a surface names its own catalog, and one that
  /// names none fails to resolve. See [resolveCatalog].
  final Catalog<T, FunctionImplementation>? defaultCatalog;

  /// The catalogs a component or function call on this surface may name by
  /// `catalogId`, keyed by id. Includes [defaultCatalog] when there is one.
  final Map<String, Catalog<T, FunctionImplementation>> availableCatalogs;

  final Map<String, dynamic> theme;
  final bool sendDataModel;
  final String? protocolVersion;

  /// The id of the component this surface's tree is rooted at.
  ///
  /// `root` unless set otherwise. `NodeResolver` builds the tree from it, and
  /// `MessageProcessor` checks for it when `ValidationConfig.rootId` is null.
  final String rootId;

  final DataModel dataModel;
  final SurfaceComponentsModel componentsModel;

  final _onAction = EventNotifier<A2uiClientAction>();
  final _onError = EventNotifier<A2uiClientError>();

  /// Fires whenever an action is dispatched from this surface.
  EventListenable<A2uiClientAction> get onAction => _onAction;

  /// Fires whenever an error occurs on this surface.
  EventListenable<A2uiClientError> get onError => _onError;

  /// Creates a surface with [defaultCatalog], which is null for a v1.0
  /// surface that names none.
  ///
  /// [availableCatalogs] are the further catalogs its components and function
  /// calls may name by `catalogId`; [defaultCatalog] is added to them.
  SurfaceModel(
    this.id, {
    required this.defaultCatalog,
    Iterable<Catalog<T, FunctionImplementation>> availableCatalogs = const [],
    this.theme = const {},
    this.sendDataModel = false,
    this.protocolVersion,
    this.rootId = 'root',
  })  : availableCatalogs =
            Map.unmodifiable(<String, Catalog<T, FunctionImplementation>>{
          for (final Catalog<T, FunctionImplementation> c in availableCatalogs)
            c.id: c,
          if (defaultCatalog != null) defaultCatalog.id: defaultCatalog,
        }),
        dataModel = DataModel(),
        componentsModel = SurfaceComponentsModel(catalog: defaultCatalog);

  /// The catalog an item on this surface resolves to.
  ///
  /// A v1.0 component or function call uses the catalog its [catalogId]
  /// names, or else the surface's [defaultCatalog]. [subject] names the item
  /// in the error, such as `"Component 'root'"`.
  ///
  /// Throws [A2uiCatalogError] when [catalogId] names a catalog this surface
  /// does not have, or when it is null and the surface has no default.
  Catalog<T, FunctionImplementation> resolveCatalog(
    String? catalogId, {
    String subject = 'Item',
  }) {
    if (catalogId != null) {
      return availableCatalogs[catalogId] ??
          (throw A2uiCatalogError(
            'Catalog not found: $catalogId. $subject names a catalog surface '
            "'$id' does not have. "
            "Available: ${availableCatalogs.keys.join(', ')}.",
            catalogId: catalogId,
          ));
    }
    return defaultCatalog ??
        (throw A2uiCatalogError(
          "$subject names no catalogId and surface '$id' has no default "
          'catalogId.',
        ));
  }

  /// The catalog [component] resolved to, its [ComponentModel.catalog], typed
  /// for this surface.
  ///
  /// The catalog was resolved when the component arrived (see
  /// [resolveCatalog]), so it is not re-derived from the component's
  /// properties here. Throws [A2uiCatalogError] when that catalog does not
  /// hold components of type [T], which only a component built outside
  /// `MessageProcessor` can cause.
  Catalog<T, FunctionImplementation> catalogForComponent(
    ComponentModel component,
  ) {
    final Catalog<ComponentApi, FunctionImplementation> catalog =
        component.catalog;
    if (catalog is Catalog<T, FunctionImplementation>) return catalog;
    throw A2uiCatalogError(
      "Component '${component.id}' is in catalog '${catalog.id}', whose "
      "components are not $T as surface '$id' requires.",
      catalogId: catalog.id,
    );
  }

  /// Invokes [call] in the catalog its [FunctionCall.catalogId] resolves to;
  /// see [resolveCatalog]. Matches [FunctionInvoker], so it can be passed to
  /// a [DataContext] as is.
  ///
  /// Throws [A2uiCatalogError] when the call resolves to no catalog, and
  /// [A2uiExpressionError] when the catalog it resolves to has no such
  /// function.
  Object? invokeFunction(
    FunctionCall call,
    Map<String, dynamic> args,
    DataContext context,
  ) =>
      resolveCatalog(call.catalogId, subject: "Function call '${call.call}'")
          .invoke(call.call, args, context);

  /// Emits an agent-bound action from this surface on [onAction].
  ///
  /// The [payload] is either `{'event': {'name': ..., 'context': ...,
  /// 'userMessage': ...}}` or the same fields without the `event` wrapper.
  /// Its values must already be resolved against the data model.
  ///
  /// Any other payload, including a `functionCall` or `call` action, or an
  /// event whose `name` is missing, empty, or not a string, is reported on
  /// [onError] with code `'INVALID_ACTION'` and not emitted on [onAction].
  /// Local function actions run in `GenericBinder`, which calls this method
  /// only for actions that go to the agent.
  Future<void> dispatchAction(
    Map<String, dynamic> payload,
    String sourceComponentId,
  ) async {
    final Map<String, dynamic> event;
    if (payload.containsKey('event') && payload['event'] is Map) {
      event = Map<String, dynamic>.from(payload['event'] as Map);
    } else if (payload.containsKey('name')) {
      event = payload;
    } else {
      await dispatchError(
        A2uiClientError(
          code: 'INVALID_ACTION',
          surfaceId: id,
          message: "Invalid action payload in component '$sourceComponentId': "
              'missing event or action name.',
          details: payload,
        ),
      );
      return;
    }

    final Object? name = event['name'];
    if (name is! String || name.isEmpty) {
      await dispatchError(
        A2uiClientError(
          code: 'INVALID_ACTION',
          surfaceId: id,
          message: "Invalid action payload in component '$sourceComponentId': "
              'action name must be a non-empty string.',
          details: payload,
        ),
      );
      return;
    }

    final Object? rawContext = event['context'];
    final Map<String, dynamic> context;
    if (rawContext is Map) {
      final Object? detached = _detach(rawContext);
      context = detached is Map<String, dynamic>
          ? detached
          : <String, dynamic>{
              for (final MapEntry<Object?, Object?> entry in rawContext.entries)
                entry.key.toString(): _detach(entry.value),
            };
    } else {
      context = const <String, dynamic>{};
    }

    final action = A2uiClientAction(
      name: name,
      surfaceId: id,
      sourceComponentId: sourceComponentId,
      timestamp: DateTime.now().toUtc(),
      context: context,
      userMessage: event['userMessage'] is String
          ? event['userMessage'] as String
          : null,
    );
    _onAction.emit(action);
    // Only event payloads are emitted; functionCall payloads are not
    // dispatched here.
  }

  /// Dispatches an error from this surface.
  Future<void> dispatchError(A2uiClientError error) async {
    _onError.emit(error);
  }

  /// Disposes of the surface and its resources.
  void dispose() {
    dataModel.dispose();
    componentsModel.dispose();
    _onAction.dispose();
    _onError.dispose();
  }
}

/// Copies maps and lists, so an action listener cannot reach the component or
/// data model the payload was resolved from.
Object? _detach(Object? value) => switch (value) {
      Map() when value.keys.every((key) => key is String) => <String, dynamic>{
          for (final MapEntry<Object?, Object?> entry in value.entries)
            entry.key as String: _detach(entry.value),
        },
      Map() => <Object?, Object?>{
          for (final MapEntry<Object?, Object?> entry in value.entries)
            entry.key: _detach(entry.value),
        },
      List() => <Object?>[for (final Object? item in value) _detach(item)],
      _ => value,
    };
