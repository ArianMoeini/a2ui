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

import 'package:json_schema_builder/json_schema_builder.dart';

import '../core/catalog.dart';
import '../core/component_model.dart';
import '../core/messages.dart';
import '../core/surface_group_model.dart';
import '../core/surface_model.dart';
import '../primitives/errors.dart';
import '../primitives/protocol_version.dart';
import '../validation/component_graph.dart';
import '../validation/nested_calls.dart';
import '../validation/validation_config.dart';
import '../validation/validator.dart';

/// The central processor for A2UI messages on renderer side.
///
/// It consumes the agent-to-renderer messages
/// (`createSurface`, `updateComponents`, `updateDataModel`, `deleteSurface`)
/// and builds the surface state a renderer draws from. An agent can also run
/// it headlessly, to evaluate the UI its own payload would produce.
///
/// Not to be confused with the Agent SDK's `A2uiRequestProcessor`, which runs
/// the other way: it parses model output into the payloads this consumes.
///
/// This is the entry point for validation as well as for processing, because
/// it is what holds every supported [catalogs] entry and can therefore decide
/// which catalog each item belongs to. [PayloadValidator] checks one component,
/// function call or theme against one catalog; the processor resolves that
/// catalog per item and calls [validatorFor] for it. That split is what lets a
/// surface mix catalogs, which v1.0 allows through the `catalogId` a component
/// or function call may carry to override the surface-level default.
///
/// [processMessages] is the entry point for both sides. It takes an
/// [AgentToRendererMessagePayload] — a batch of parsed messages, a lone
/// message, or raw decoded JSON — and applies it to the surface state,
/// checking each message against the surface it joins as it goes, so graph
/// checks resolve references against what the surface already holds. An agent
/// checks its own output the same way, over a processor it keeps for the
/// session: the state it builds up is what makes an incremental update
/// checkable rather than waved through.
///
/// Validation runs per message. Envelopes are checked as the payload is
/// parsed, a surface's theme when the surface is created, and each
/// `updateComponents` batch before any of it is applied: duplicate ids within
/// the batch, every component against its catalog's schema, and, when the
/// processor has a [validationConfig], the surface the batch would leave
/// behind (the components already there, with the batch applied on top) as
/// one graph. Without a config the graph is not checked, so a surface may
/// arrive across several messages in any order; see [ValidationConfig].
class MessageProcessor<T extends ComponentApi> {
  final SurfaceGroupModel<T> groupModel;
  final List<Catalog<T, FunctionImplementation>> catalogs;

  /// The protocol version this processor accepts, on envelopes and in the
  /// validators it builds.
  ///
  /// Required rather than defaulted: a default would silently move every
  /// caller onto the next protocol version the day this SDK implements one.
  final A2uiProtocolVersion protocolVersion;

  /// The shared `common_types.json` definitions the validators resolve
  /// against.
  ///
  /// Defaults to the copy this package publishes for [protocolVersion]; pass
  /// a different document to override it, or an empty map to leave the shared
  /// types unchecked.
  final Map<String, Object?> commonTypesSchema;

  /// Which checks each message must pass, or null, the default, for none of
  /// the graph checks.
  ///
  /// With a config, every `updateComponents` must leave its surface a graph
  /// the config's flags accept; [ValidationConfig.strict] requires a root,
  /// references that resolve and every component reachable from the root,
  /// which a surface delivered across several messages satisfies only once
  /// the last of them has arrived. Without a config, duplicate ids within a
  /// batch and the schemas of declared component types are still checked.
  final ValidationConfig? validationConfig;

  /// One validator per catalog, built on first use.
  final Map<String, PayloadValidator<T, FunctionImplementation>> _validators =
      {};

  MessageProcessor({
    required this.catalogs,
    required this.protocolVersion,
    this.validationConfig,
    Map<String, Object?>? commonTypesSchema,
    void Function(A2uiClientAction)? onAction,
  })  : commonTypesSchema = commonTypesSchema ??
            PayloadValidator.commonTypesFor(protocolVersion),
        groupModel = SurfaceGroupModel<T>() {
    final A2uiProtocolVersion? target = validationConfig?.targetVersion;
    if (target != null && target != protocolVersion) {
      throw A2uiValidationError(
        "ValidationConfig.targetVersion is '${target.jsonValue}' but this "
        "processor is built for '${protocolVersion.jsonValue}'.",
      );
    }
    if (onAction != null) {
      groupModel.onAction.addListener(onAction);
    }
  }

  /// The validator for [catalog].
  ///
  /// A component belongs to exactly one catalog, so a validator is scoped to
  /// one rather than handed the whole supported set. The processor is what
  /// routes each item to the right one, which is what keeps a component of one
  /// catalog from passing on a surface whose default is another, and what lets
  /// a v1.0 surface mix catalogs.
  ///
  /// Built once per catalog and reused. The validator caches resolved
  /// component schemas, which a fresh instance per batch would rebuild on
  /// every message.
  ///
  /// A v1.0 function call nested in a component runs in the catalog it
  /// resolves to, not necessarily the component's. The component's validator
  /// checks the calls that run in the component's catalog (see
  /// `nestedCallRunsInCatalog`), and the processor checks each other call
  /// against the catalog it resolves to.
  PayloadValidator<T, FunctionImplementation> validatorFor(
    Catalog<T, FunctionImplementation> catalog,
  ) =>
      _validators.putIfAbsent(
        catalog.id,
        () => PayloadValidator<T, FunctionImplementation>(
          catalog: catalog,
          commonTypesSchema: commonTypesSchema,
          protocolVersion: protocolVersion,
          // Without a config nothing is being validated against the graph,
          // and an undeclared type is tolerated too.
          allowUnknownElements: validationConfig?.allowUnknownElements ?? true,
        ),
      );

  /// The supported catalog with [catalogId].
  ///
  /// Throws [A2uiCatalogError] when this processor supports no such catalog,
  /// which for a renderer means the agent named a catalog outside the
  /// capabilities it advertised.
  Catalog<T, FunctionImplementation> catalogFor(String catalogId) {
    for (final Catalog<T, FunctionImplementation> catalog in catalogs) {
      if (catalog.id == catalogId) return catalog;
    }
    throw A2uiCatalogError(
      "Catalog '$catalogId' is not supported by this processor. Supported: "
      '${catalogs.map((c) => c.id).join(', ')}.',
      catalogId: catalogId,
    );
  }

  /// Processes a payload, applying each message to the surface it names.
  ///
  /// Each message is checked as it is applied, against the surface state the
  /// earlier messages left behind, and a message that fails leaves its surface
  /// as it was. For an `updateComponents` message that means its components
  /// against the catalog each belongs to, then, under a [validationConfig],
  /// the surface it would leave behind: a payload that declares a parent in
  /// one `updateComponents` and its child in a later one needs
  /// [ValidationConfig.allowDanglingReferences], or both in one message, or
  /// no config.
  ///
  /// A caller holding a raw payload parses it first, with
  /// `AgentToRendererMessagePayload.fromJson(payload, protocolVersion: ...)`.
  /// That is a separate step because envelope parsing needs no catalog and no
  /// surface: it is what lets a payload be read before each message is matched
  /// to the surface, and so the catalog, it belongs to.
  ///
  /// Throws [A2uiIntegrityError] for a message naming a surface that does not
  /// exist, a duplicate id, and under a config a missing root, a reference to
  /// no component or an unreachable component; [A2uiRecursionError] under a
  /// config for a cycle or an over-deep chain; [A2uiCatalogError] for a
  /// catalog this processor does not support; and [A2uiValidationError] for a
  /// component that does not match its catalog or a message
  /// [ValidationConfig.allowedMessages] does not list.
  void processMessages(AgentToRendererMessagePayload payload) {
    for (final AgentToRendererMessage message in payload.messages) {
      _processMessage(message);
    }
  }

  /// Alias for [processMessages] for cross-SDK ergonomics.
  void process(AgentToRendererMessagePayload payload) =>
      processMessages(payload);

  /// The envelope fields of a component message, which a [ComponentModel]
  /// holds apart from its properties.
  static const Set<String> _envelopeFields = {
    'id',
    'component',
    'catalogId',
    'metadata',
  };

  /// The catalog one component is checked against.
  ///
  /// Settled in order: the `catalogId` the component names for itself, which
  /// v1.0 allows so that one surface can mix catalogs; then the surface's
  /// default, from `createSurface`. An entry that names its type replaces the
  /// component whole, so one that names no catalog resolves to the default
  /// like any other component; only a pre-v1.0 entry that omits `component`
  /// keeps the existing component's `catalogId` (see [_resolveComponent]).
  /// There is no fallback to a catalog the surface did not name either: from
  /// v1.0 a surface may name no default, and a component that names no
  /// catalog on it fails to resolve.
  ///
  /// Throws [A2uiCatalogError] when neither settles it, or when the component
  /// names a catalog this processor does not support. Skipping the component
  /// instead would report a payload valid that nothing had checked. Throws
  /// [A2uiValidationError] when the component's `catalogId` is not a string,
  /// which would otherwise fall back to the default unnoticed.
  Catalog<T, FunctionImplementation> _catalogForComponent(
    Map<String, Object?> component,
    SurfaceModel<T> surface,
  ) {
    switch (component['catalogId']) {
      case final String declared:
        return catalogFor(declared);
      case final Object declared:
        throw A2uiValidationError(
          "Component '${component['id']}' has a non-string 'catalogId'.",
          details: declared,
        );
    }
    return surface.defaultCatalog ??
        (throw A2uiCatalogError(
          "Component '${component['id']}' names no catalogId and surface "
          "'${surface.id}' has no default catalogId.",
        ));
  }

  /// [component] as [catalog]'s validator is given it, which tells the
  /// validator whether the component is in the surface default catalog.
  ///
  /// From v1.0 a function call that names no `catalogId` runs in the surface
  /// default, and the validator takes a component that names no `catalogId`
  /// to be in that catalog. What decides it is the catalog the component
  /// resolved to, not whether the payload wrote a `catalogId`: one that
  /// explicitly names the surface default is in it, so its catalogless calls
  /// are checked by the validator. So `catalogId` is set to [catalog]'s id
  /// when [catalog] is not the surface default, and left out when it is.
  /// Before v1.0 a call runs in its component's catalog, so [component] is
  /// passed unchanged.
  Map<String, Object?> _componentForValidator(
    Map<String, Object?> component,
    Catalog<T, FunctionImplementation> catalog,
    SurfaceModel<T> surface, {
    required bool atLeastV1,
  }) {
    if (!atLeastV1) return component;
    return <String, Object?>{
      for (final MapEntry<String, Object?> entry in component.entries)
        if (entry.key != 'catalogId') entry.key: entry.value,
      if (!identical(catalog, surface.defaultCatalog)) 'catalogId': catalog.id,
    };
  }

  /// The reserved system function that every v1.0 surface provides, whatever
  /// its catalogs. Names in the `@` namespace belong to no catalog.
  static const String _indexFunction = '@index';

  /// Checks every v1.0 function call nested in [component]'s properties
  /// against the catalog the call resolves to.
  ///
  /// A call runs in the catalog its own `catalogId` names, or else in the
  /// surface's default catalog — not necessarily the catalog of the component
  /// that holds it, [componentCatalog]. See `SurfaceModel.resolveCatalog`.
  /// Every call's catalog is resolved. The arguments of a call that runs in
  /// [componentCatalog] (see `nestedCallRunsInCatalog`) were checked by
  /// `PayloadValidator.validateComponent`, so only the other calls' arguments
  /// are checked here.
  ///
  /// Throws [A2uiCatalogError] when a call names a catalog the surface does
  /// not have, or names none on a surface with no default, and
  /// [A2uiValidationError] when the resolved catalog declares no such
  /// function or the arguments do not match its schema.
  void _validateNestedFunctionCalls(
    Map<String, Object?> component,
    Catalog<T, FunctionImplementation> componentCatalog,
    SurfaceModel<T> surface,
  ) {
    final Object? componentId = component['id'];
    final bool catalogIsDefault = identical(
      componentCatalog,
      surface.defaultCatalog,
    );

    void visit(Object? node) {
      if (node is List) {
        node.forEach(visit);
        return;
      }
      if (node is! Map) return;
      final Object? name = node['@call'];
      if (name is String) {
        final Object? catalogId = node['catalogId'];
        if (catalogId != null && catalogId is! String) {
          throw A2uiValidationError(
            "Function call '$name' in component '$componentId' has a "
            "non-string 'catalogId'.",
            details: node,
          );
        }
        final Object? rawArgs = node['args'];
        final Map<String, Object?> args = switch (rawArgs) {
          null => const <String, Object?>{},
          final Map<Object?, Object?> map => map.cast<String, Object?>(),
          _ => throw A2uiValidationError(
              "Function call '$name' in component '$componentId' has "
              "non-object 'args'.",
              details: node,
            ),
        };
        if (name.startsWith('@')) {
          // A system function belongs to no catalog, so it is not resolved
          // against one; its arguments are still visited below.
          _validateSystemFunction(name, args, node, componentId);
        } else {
          final Catalog<T, FunctionImplementation> catalog =
              surface.resolveCatalog(
            catalogId as String?,
            subject: "Function call '$name' in component '$componentId'",
          );
          if (!nestedCallRunsInCatalog(
            catalogId,
            componentCatalog.id,
            catalogIsDefault: catalogIsDefault,
          )) {
            validatorFor(catalog)
                .validateFunctionArgs(name, args, componentId: componentId);
          }
        }
      }
      node.values.forEach(visit);
    }

    for (final MapEntry<String, Object?> entry in component.entries) {
      if (_envelopeFields.contains(entry.key)) continue;
      visit(entry.value);
    }
  }

  /// Checks a call to a reserved `@`-prefixed system function, which no
  /// catalog declares. v1.0 defines only `@index`, whose arguments are an
  /// optional `offset` (`IndexSystemFunction` in `common_types.json`).
  ///
  /// Throws [A2uiValidationError] for a system function v1.0 does not define,
  /// for one that names a `catalogId` (system functions belong to no
  /// catalog), or for arguments other than the optional `offset`.
  static void _validateSystemFunction(
    String name,
    Map<String, Object?> args,
    Map<Object?, Object?> node,
    Object? componentId,
  ) {
    if (name != _indexFunction) {
      throw A2uiValidationError(
        "Function call '$name' in component '$componentId' names an unknown "
        "system function. The '@' namespace is reserved; only "
        "'$_indexFunction' is defined.",
        details: node,
      );
    }
    if (node.containsKey('catalogId')) {
      throw A2uiValidationError(
        "Function call '$name' in component '$componentId' names a "
        "catalogId, but '$_indexFunction' is a system function and belongs "
        'to no catalog.',
        details: node,
      );
    }
    for (final String key in args.keys) {
      if (key != 'offset') {
        throw A2uiValidationError(
          "Function call '$name' in component '$componentId' has unknown "
          "argument '$key'; '$_indexFunction' takes only 'offset'.",
          details: node,
        );
      }
    }
  }

  /// Whether this processor follows protocol v1.0 or later.
  ///
  /// [protocolVersion] is the one source of truth for version-gated rules:
  /// the validators, [SurfaceModel] and `DataContext` all read it, so the
  /// processor does too, and [_checkMessageVersion] rejects a message that
  /// declares a version this processor does not accept.
  bool get _atLeastV1 => protocolVersion.isAtLeast(A2uiProtocolVersion.v1_0);

  /// Throws [A2uiValidationError] when [message] declares a protocol version
  /// incompatible with [protocolVersion].
  ///
  /// `AgentToRendererMessagePayload.fromJson(protocolVersion:)` already
  /// rejects such envelopes, but the message constructors are public, so a
  /// caller may build a v0.9 message and hand it to a v1.0 processor. Without
  /// this check it would be validated under one version's rules and applied
  /// under the other's. v0.9 and v0.9.1 share their message shapes and are
  /// accepted for each other, as the payload parsers do; from v1.0 versions
  /// with the same major number are compatible.
  void _checkMessageVersion(AgentToRendererMessage message) {
    final String declared = message.version;
    if (declared.isEmpty) return;
    final A2uiProtocolVersion? version = A2uiProtocolVersion.tryParse(declared);
    if (version == null || !_compatible(version, protocolVersion)) {
      throw A2uiValidationError(
        "Message declares protocol version '$declared', which this processor "
        "does not accept; it processes '${protocolVersion.jsonValue}'.",
      );
    }
  }

  /// Whether [a] and [b] share their message shapes: v0.9 and v0.9.1 do, and
  /// from v1.0 versions with the same major number do.
  static bool _compatible(A2uiProtocolVersion a, A2uiProtocolVersion b) =>
      a.major == b.major && (a.major >= 1 || a.minor == b.minor);

  void _processMessage(AgentToRendererMessage message) {
    final List<String>? allowed = validationConfig?.allowedMessages;
    if (allowed != null) {
      // Named by type rather than read from `toJson`, which would serialize
      // a whole component batch just to find its key.
      final String name = switch (message) {
        CreateSurfaceMessage() => 'createSurface',
        UpdateComponentsMessage() => 'updateComponents',
        UpdateDataModelMessage() => 'updateDataModel',
        DeleteSurfaceMessage() => 'deleteSurface',
        _ => message.runtimeType.toString(),
      };
      if (!allowed.contains(name)) {
        throw A2uiValidationError(
          "Message '$name' is not permitted by "
          'ValidationConfig.allowedMessages.',
        );
      }
    }

    _checkMessageVersion(message);
    final bool atLeastV1 = _atLeastV1;

    // Data-model paths and nested function calls, which need no surface state
    // and so are checked for every message before it is applied. Part of the
    // validation a config turns on.
    if (validationConfig != null) {
      checkPathsAndRecursion(message, v1: atLeastV1);
    }

    if (message is CreateSurfaceMessage) {
      _processCreateSurface(message, atLeastV1: atLeastV1);
    } else if (message is UpdateComponentsMessage) {
      _processUpdateComponents(message, atLeastV1: atLeastV1);
    } else if (message is UpdateDataModelMessage) {
      _processUpdateDataModel(message);
    } else if (message is DeleteSurfaceMessage) {
      _processDeleteSurface(message);
    }
  }

  void _processCreateSurface(
    CreateSurfaceMessage message, {
    required bool atLeastV1,
  }) {
    // From v1.0 the default catalog is optional: a surface that names none
    // has none, and every component and function call on it names its own.
    // Before v1.0 a surface must name one.
    final String? catalogId = message.catalogId;
    if (catalogId == null && !atLeastV1) {
      throw A2uiValidationError(
        "Message 'createSurface' for surface '${message.surfaceId}' names "
        'no catalogId.',
      );
    }
    final Catalog<T, FunctionImplementation>? catalog =
        catalogId == null ? null : catalogFor(catalogId);

    if (groupModel.getSurface(message.surfaceId) != null) {
      throw A2uiIntegrityError('Surface ${message.surfaceId} already exists.');
    }

    // The theme arrives once, with the surface, so it is checked here rather
    // than on every later message. A surface with no default catalog has no
    // theme schema to check it against.
    if (catalog != null) validatorFor(catalog).validateTheme(message.theme);

    final surface = SurfaceModel<T>(
      message.surfaceId,
      defaultCatalog: catalog,
      availableCatalogs: catalogs,
      theme: message.theme ?? {},
      sendDataModel: message.sendDataModel,
      protocolVersion: protocolVersion.jsonValue,
      rootId: validationConfig?.rootId ?? 'root',
    );
    groupModel.addSurface(surface);
  }

  SurfaceModel<T> _surfaceFor(String surfaceId) {
    final SurfaceModel<T>? surface = groupModel.getSurface(surfaceId);
    if (surface == null) {
      throw A2uiIntegrityError('Surface not found for message: $surfaceId');
    }
    return surface;
  }

  void _processUpdateComponents(
    UpdateComponentsMessage message, {
    required bool atLeastV1,
  }) {
    final SurfaceModel<T> surface = _surfaceFor(message.surfaceId);
    final SurfaceComponentsModel model = surface.componentsModel;

    // Pass 1: validation.
    //
    // Every component in the batch is resolved to a full entry and to the
    // catalog it belongs to, and checked, before any of them is applied, so a
    // batch that is rejected leaves the surface exactly as it was. The
    // catalog is kept for the model pass 2 builds, so it is resolved once.
    final List<(Map<String, Object?>, Catalog<T, FunctionImplementation>)>
        resolved = [
      for (final Map<String, dynamic> raw in message.components)
        _resolveComponent(
          raw.cast<String, Object?>(),
          surface,
          atLeastV1: atLeastV1,
        ),
    ];
    final List<Map<String, Object?>> entries = [
      for (final (Map<String, Object?> entry, _) in resolved) entry,
    ];

    // The surface this batch would leave behind, as one graph: duplicate ids,
    // then under a config the root, references that resolve, cycles, depth
    // and reachability, as its flags require. Each component's references
    // are read through the catalog it resolved to.
    final ValidationConfig? config = validationConfig;
    if (config == null) {
      checkDuplicateComponentIds(entries);
    } else {
      final catalogsById = <Object?, Catalog<T, FunctionImplementation>>{
        for (final (Map<String, Object?> entry, catalog) in resolved)
          entry['id']: catalog,
      };
      model.checkComponentsUpdate(
        entries,
        config,
        catalogOf: (Map<String, Object?> entry) => catalogsById[entry['id']],
        defaultRootId: surface.rootId,
      );
    }

    // Pass 2: mutation. Only reached when the whole batch is valid.
    for (final (Map<String, Object?> entry, catalog) in resolved) {
      final id = entry['id']! as String;
      final type = entry['component']! as String;
      final catalogId = entry['catalogId'] as String?;
      final Map<String, Object?>? metadata = switch (entry['metadata']) {
        final Map<Object?, Object?> map => Map<String, Object?>.from(map),
        _ => null,
      };
      final props = <String, dynamic>{
        for (final MapEntry<String, Object?> e in entry.entries)
          if (!_envelopeFields.contains(e.key)) e.key: e.value,
      };

      final ComponentModel? existing = model.get(id);
      if (existing != null &&
          existing.type == type &&
          identical(existing.catalog, catalog)) {
        existing.catalogId = catalogId;
        existing.metadata = metadata;
        existing.properties = props;
        continue;
      }
      // A new component, or one whose type or catalog changed, which is
      // recreated rather than updated in place.
      if (existing != null) model.removeComponent(id);
      model.addComponent(
        ComponentModel(
          id,
          type,
          props,
          catalog: catalog,
          catalogId: catalogId,
          metadata: metadata,
        ),
      );
    }
  }

  /// Resolves one `updateComponents` entry to the full component it describes
  /// and the catalog it belongs to, and checks it against that catalog.
  ///
  /// Before v1.0 an entry that omits `component` updates a component the
  /// surface already holds: it keeps that component's type, and its
  /// `catalogId` and `metadata` when it omits those too. Its properties
  /// replace the existing ones, so the entry is checked against the type's
  /// schema as it stands. From v1.0 every entry must name its type.
  ///
  /// An entry that names `component` replaces the component whole: one that
  /// omits `catalogId` belongs to the surface's default catalog, so a
  /// component that named a catalog of its own is recreated, as for a change
  /// of type. See [_catalogForComponent].
  (Map<String, Object?>, Catalog<T, FunctionImplementation>) _resolveComponent(
    Map<String, Object?> entry,
    SurfaceModel<T> surface, {
    required bool atLeastV1,
  }) {
    final Object? id = entry['id'];
    if (id is! String) {
      throw A2uiValidationError("Component missing an 'id'.", details: entry);
    }
    final Object? rawType = entry['component'];
    final Object? rawCatalog = entry['catalogId'];
    final Object? rawMetadata = entry['metadata'];
    if (rawType != null && rawType is! String) {
      throw A2uiValidationError(
        "Component '$id' has a 'component' type that is not a string.",
        details: entry,
      );
    }
    if (rawCatalog != null && rawCatalog is! String) {
      throw A2uiValidationError(
        "Component '$id' has a non-string 'catalogId'.",
        details: entry,
      );
    }
    if (rawMetadata != null &&
        (rawMetadata is! Map || rawMetadata.keys.any((k) => k is! String))) {
      // Checked here because a lazy `cast` would let a non-string key escape
      // later as a `TypeError` rather than a payload error.
      throw A2uiValidationError(
        "Component '$id' has 'metadata' that is not an object with string "
        'keys.',
        details: entry,
      );
    }

    final ComponentModel? existing = surface.componentsModel.get(id);
    final partial = rawType == null;
    final String? type = rawType as String? ?? existing?.type;
    if (type == null) {
      throw A2uiValidationError(
        "Cannot create component $id without a 'component' type.",
        details: entry,
      );
    }
    // From v1.0 an update replaces the component whole, and the spec
    // requires `component` on every component object, so an update cannot
    // omit it and inherit the previous type.
    if (atLeastV1 && partial) {
      throw A2uiValidationError(
        "Component $id names no 'component' type. From v1.0 every "
        'component in updateComponents must name its type.',
        details: entry,
      );
    }
    final String? catalogId =
        rawCatalog as String? ?? (partial ? existing?.catalogId : null);
    final Object? metadata =
        rawMetadata ?? (partial ? existing?.metadata : null);

    final full = <String, Object?>{
      ...entry,
      'component': type,
      if (catalogId != null) 'catalogId': catalogId,
      if (metadata != null) 'metadata': metadata,
    };

    final Catalog<T, FunctionImplementation> catalog =
        _catalogForComponent(full, surface);
    validatorFor(catalog).validateComponent(
      _componentForValidator(full, catalog, surface, atLeastV1: atLeastV1),
    );
    // From v1.0 each nested function call resolves its own catalog, which
    // need not be the component's. Every v1.0 entry names a type (checked
    // above), so no component skips this.
    if (atLeastV1) _validateNestedFunctionCalls(full, catalog, surface);
    return (full, catalog);
  }

  void _processUpdateDataModel(UpdateDataModelMessage message) {
    final SurfaceModel<T> surface = _surfaceFor(message.surfaceId);
    surface.dataModel.set(message.path ?? '/', message.value);
  }

  /// Deletes the surface, or does nothing if no surface has that id, matching
  /// the conformance suite and the TypeScript and Python SDKs.
  void _processDeleteSurface(DeleteSurfaceMessage message) {
    groupModel.deleteSurface(message.surfaceId);
  }

  /// Generates client capabilities.
  Map<String, dynamic> getClientCapabilities({
    bool includeInlineCatalogs = false,
  }) {
    final v09 = <String, dynamic>{
      'supportedCatalogIds': catalogs.map((c) => c.id).toList(),
    };

    if (includeInlineCatalogs) {
      v09['inlineCatalogs'] = catalogs.map(_generateInlineCatalog).toList();
    }

    return {'v0.9': v09};
  }

  Map<String, dynamic> _generateInlineCatalog(
    Catalog<T, FunctionImplementation> catalog,
  ) {
    final components = <String, dynamic>{};
    for (final MapEntry<String, T> entry in catalog.components.entries) {
      final Map<String, dynamic> jsonSchema = entry.value.schema.toJsonMap();
      _processRefs(jsonSchema);

      // Wrap in A2UI envelope
      components[entry.key] = {
        'allOf': [
          {'\$ref': 'common_types.json#/\$defs/ComponentCommon'},
          {
            'properties': {
              'component': {'const': entry.key},
              ...?(jsonSchema['properties'] as Map<String, dynamic>?),
            },
            'required': ['component', ...?(jsonSchema['required'] as List?)],
          },
        ],
      };
    }

    final List<Map<String, Object>> functions = catalog.functions.values.map((
      f,
    ) {
      final Map<String, dynamic> jsonSchema = f.argumentSchema.toJsonMap();
      _processRefs(jsonSchema);
      return {
        'name': f.name,
        'returnType': f.returnType.jsonValue,
        'parameters': jsonSchema,
      };
    }).toList();

    Map<String, dynamic>? theme;
    if (catalog.themeSchema != null) {
      theme = catalog.themeSchema!.toJsonMap();
      _processRefs(theme);
      theme = theme['properties'] as Map<String, dynamic>?;
    }

    return {
      'catalogId': catalog.id,
      if (components.isNotEmpty) 'components': components,
      if (functions.isNotEmpty) 'functions': functions,
      if (theme != null) 'theme': theme,
    };
  }

  void _processRefs(Object? node) {
    if (node is! Map) return;

    if (node['description'] is String &&
        (node['description'] as String).startsWith('REF:')) {
      final desc = node['description'] as String;
      final List<String> parts = desc.substring(4).split('|');
      final String ref = parts[0];
      final String? actualDesc = parts.length > 1 ? parts[1] : null;

      node.clear();
      node['\$ref'] = ref;
      if (actualDesc != null) {
        node['description'] = actualDesc;
      }
      return;
    }

    node.forEach((key, value) {
      if (value is Map) {
        _processRefs(value);
      } else if (value is List) {
        for (final Object? item in value) {
          if (item is Map) {
            _processRefs(item);
          }
        }
      }
    });
  }

  /// Aggregates data models for surfaces with sendDataModel enabled.
  ///
  /// The result is the data model envelope for [version], which defaults to
  /// [protocolVersion]. Only surfaces whose protocol version is compatible
  /// with [version] are part of it: v0.9 and v0.9.1 are compatible with each
  /// other, and from v1.0 versions with the same major number are. Returns
  /// null when no such surface sends its data model.
  Map<String, dynamic>? getClientDataModel({A2uiProtocolVersion? version}) {
    final A2uiProtocolVersion requested = version ?? protocolVersion;
    final surfaces = <String, dynamic>{};
    for (final SurfaceModel<T> surface in groupModel.allSurfaces) {
      final A2uiProtocolVersion? surfaceVersion =
          switch (surface.protocolVersion) {
        final String declared => A2uiProtocolVersion.tryParse(declared),
        null => protocolVersion,
      };
      if (surface.sendDataModel &&
          surfaceVersion != null &&
          _compatible(surfaceVersion, requested)) {
        surfaces[surface.id] = surface.dataModel.get('/');
      }
    }

    if (surfaces.isEmpty) return null;

    return {'version': requested.jsonValue, 'surfaces': surfaces};
  }

  /// Alias for [getClientDataModel] for cross-SDK ergonomics.
  Map<String, dynamic>? getRendererDataModel({A2uiProtocolVersion? version}) =>
      getClientDataModel(version: version);
}

extension SchemaExtension on Schema {
  Map<String, dynamic> toJsonMap() => _deepCopy(value);

  static Map<String, dynamic> _deepCopy(Map<dynamic, dynamic> map) {
    return map.map((key, value) {
      if (value is Map) {
        return MapEntry(key as String, _deepCopy(value));
      }
      if (value is List) {
        return MapEntry(
          key as String,
          value.map((item) => item is Map ? _deepCopy(item) : item).toList(),
        );
      }
      return MapEntry(key as String, value);
    });
  }
}
