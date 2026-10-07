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

import 'dart:convert';

import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:meta/meta.dart';

import '../core/catalog.dart';
import '../primitives/errors.dart';
import '../primitives/protocol_version.dart';
import '../primitives/semver.dart';
import '../primitives/uax31.dart';
import 'common_types.g.dart';
import 'component_refs.dart';
import 'nested_calls.dart';
import 'schema_resolution.dart';

/// Verifies an item in an agent-to-renderer payload.
///
/// Checks one component, one function call, or one theme against one catalog.
///
/// Lives in `a2ui_core` because renderers and agents check that same payload
/// against the same catalogs. Implements v0.9 only: [checkVersion] rejects any
/// other version, or none.
///
/// A validator is scoped to a single [catalog], and validates a single item
/// against it. It deliberately does not walk a payload: from v1.0 a surface
/// may mix catalogs, because a component and a function call each carry an
/// optional `catalogId` that overrides the surface-level default. Deciding
/// which catalog an item belongs to is therefore a per-item question that only
/// something holding every supported catalog can answer, which is
/// `MessageProcessor`. It resolves the catalog for each item and calls the
/// validator for it, so a payload spanning several catalogs is checked
/// item by item rather than rejected.
///
/// Both sides, agent and renderer, reach it through
/// `MessageProcessor.processMessages`, which checks each message against the
/// surface state it holds. An agent keeps a processor for the session and
/// checks its own output the same way a renderer checks what it receives.
///
/// Every entry point is synchronous. Component schemas reach the validator
/// with their references already inlined by `resolveSchemaRefs`, so schema
/// validation runs through `Schema.validateSync` and never performs I/O. A
/// caller can therefore validate inside a synchronous message-processing path.
class PayloadValidator<C extends ComponentApi, F extends FunctionApi> {
  /// The catalog items are validated against.
  ///
  /// Every component, function call and theme this validator is given is
  /// checked against this catalog. Routing an item to the validator for its
  /// own catalog is the caller's job; see the class comment.
  final Catalog<C, F> catalog;

  /// The protocol version this validator accepts.
  final A2uiProtocolVersion protocolVersion;

  /// The shared `common_types.json` definitions this validator resolves
  /// against.
  ///
  /// Catalogs state their component properties in terms of these shared types
  /// rather than restating them. The v0.9 `basic` and `minimal` catalogs
  /// reference `ComponentCommon`, `ComponentId`, `ChildList`, `Action`,
  /// `Checkable`, `DataBinding` and the dynamic-value family (`DynamicValue`,
  /// `DynamicString`, `DynamicNumber`, `DynamicBoolean`, `DynamicStringList`),
  /// and reach `AccessibilityAttributes`, `CheckRule` and `FunctionCall`
  /// through those. [validateComponent] needs this document to check any of
  /// them; a reference `resolveSchemaRefs` cannot reach is dropped, which
  /// leaves that subschema unconstrained rather than failing.
  ///
  /// Defaults to [commonTypesFor] of [protocolVersion], this package's copy of
  /// `specification/v0_9/json/common_types.json`; pass a different document to
  /// override it, or an empty map to leave the shared types unchecked.
  ///
  /// v1.0's `specification/v1_0/json/common_types.json` keeps every one of
  /// those definitions and adds `Child`, `CallId`, `Extensions`,
  /// `FunctionCommon`, `IndexSystemFunction`, `Surface` and
  /// `FunctionResponse`. This SDK implements v0.9 only, so that document is
  /// not embedded and [commonTypesFor] cannot return it.
  final Map<String, Object?> commonTypesSchema;

  /// Whether [validateComponent] accepts a component type [catalog] does not
  /// declare, without checking it against any schema.
  final bool allowUnknownElements;

  /// [catalog]'s component schemas with their `$ref`s inlined, on first use.
  Map<String, Schema>? _resolvedComponents;

  /// [catalog]'s function argument schemas with their `$ref`s inlined, on
  /// first use.
  Map<String, Schema>? _resolvedFunctions;

  PayloadValidator({
    required this.catalog,
    required this.protocolVersion,
    Map<String, Object?>? commonTypesSchema,
    this.allowUnknownElements = false,
  }) : commonTypesSchema = commonTypesSchema ?? commonTypesFor(protocolVersion);

  /// The `common_types.json` document this package publishes for [version].
  ///
  /// A copy of `specification/<version>/json/common_types.json`, embedded at
  /// build time by `tool/generate_common_types.dart` so that a package
  /// installed from pub.dev can resolve the shared types without reading the
  /// specification repository. Each call returns a fresh document, so a caller
  /// may edit the result. v0.9.1 shares the v0.9 document.
  ///
  /// Throws [A2uiValidationError] for v1.0, whose document this package does
  /// not embed yet; pass it explicitly as `commonTypesSchema` instead.
  static Map<String, Object?> commonTypesFor(A2uiProtocolVersion version) =>
      switch (version) {
        A2uiProtocolVersion.v0_9 ||
        A2uiProtocolVersion.v0_9_1 =>
          jsonDecode(commonTypesV0_9Json) as Map<String, Object?>,
        A2uiProtocolVersion.v1_0 => throw A2uiValidationError(
            'This package does not embed the common types for protocol '
            "version '${version.jsonValue}'; pass them as "
            '`commonTypesSchema`.',
          ),
      };

  /// Creates a validator for [version].
  ///
  /// Throws [A2uiValidationError] for any version this SDK does not
  /// implement.
  factory PayloadValidator.forVersion(
    Object? version, {
    required Catalog<C, F> catalog,
    Map<String, Object?>? commonTypesSchema,
  }) =>
      PayloadValidator<C, F>(
        catalog: catalog,
        commonTypesSchema: commonTypesSchema,
        protocolVersion: A2uiProtocolVersion.fromJson(version),
      );

  /// Checks the `version` field of one payload envelope.
  ///
  /// A version compatible with [protocolVersion] (see
  /// [isCatalogVersionCompatible]) is accepted, so a v0.9 validator accepts
  /// v0.9.1 envelopes. Returns [protocolVersion], the version whose rules
  /// this validator applies.
  ///
  /// Throws [A2uiValidationError] if the version is missing or is not
  /// compatible with the version this validator accepts.
  A2uiProtocolVersion checkVersion(Map<String, Object?> envelope) {
    final A2uiProtocolVersion version = A2uiProtocolVersion.fromJson(
      envelope['version'],
      details: envelope,
    );
    if (!isCatalogVersionCompatible(
      version.jsonValue,
      protocolVersion.jsonValue,
    )) {
      throw A2uiValidationError(
        "Payload declares version '${version.jsonValue}' but this validator "
        "accepts only versions compatible with '${protocolVersion.jsonValue}'.",
        details: envelope,
      );
    }
    return protocolVersion;
  }

  /// Checks one component against [catalog]'s schema for its type.
  ///
  /// The caller decides which catalog the component belongs to; this checks it
  /// against the one catalog this validator holds.
  ///
  /// A type the catalog does not declare is accepted unchecked when
  /// [allowUnknownElements] is true.
  ///
  /// From v1.0 a function call nested in the component runs in the catalog
  /// its own `catalogId` names, or else in the surface's default catalog. A
  /// nested call that runs in [catalog] is checked against [catalog]'s
  /// function schemas: one that names [catalog]'s id, or names no
  /// `catalogId` in a component that names none either. A component with no
  /// `catalogId` is taken to be in the surface default catalog, where calls
  /// that name none run. Any other call runs in a catalog this validator
  /// can't see, so it is checked only for what needs no catalog: its
  /// function and argument names must be UAX #31 identifiers.
  /// `MessageProcessor` resolves such a call's catalog and checks it there.
  /// An empty `catalogId` names a catalog too, and a non-string `catalogId`
  /// is an error. A name in the reserved `@` namespace must be `@index`.
  ///
  /// Throws [A2uiValidationError] if the component names no type, names one
  /// the catalog does not declare, or does not match its schema, if a nested
  /// call this catalog judges does not match [catalog]'s function schemas, or
  /// if a nested v1.0 function call has a non-string `catalogId`, a name or
  /// argument name that is not an identifier, or calls a system function
  /// other than `@index`. A nested call this catalog judges is checked before
  /// the component's own schema, so the error names that call and, for bad
  /// arguments, the argument.
  void validateComponent(Map<String, Object?> component) {
    component = _jsonMap(component);
    final Object? type = component['component'];
    if (type is! String) {
      throw A2uiValidationError(
        "Component '${component['id']}' does not name a component type.",
        details: component,
      );
    }
    final bool atLeastV1 = protocolVersion.isAtLeast(A2uiProtocolVersion.v1_0);
    if (atLeastV1) {
      for (final MapEntry<String, Object?> entry in component.entries) {
        _checkCallIdentifiers(entry.value, component['id']);
      }
    }
    final Schema? schema = _resolvedComponentSchemas[type];
    if (schema == null) {
      if (allowUnknownElements) return;
      throw A2uiValidationError(
        "Catalog '${catalog.id}' declares no component named '$type'.",
        details: component,
      );
    }
    if (atLeastV1) {
      for (final MapEntry<String, Object?> entry in component.entries) {
        if (entry.key == 'id' ||
            entry.key == 'component' ||
            entry.key == 'catalogId') {
          continue;
        }
        _checkNestedCalls(
          entry.value,
          componentId: component['id'],
          componentCatalogId: component['catalogId'],
        );
      }
    }

    final Map<Object?, Object?> rawProps = switch (schema.value['properties']) {
      final Map<Object?, Object?> map => map,
      _ => const <Object?, Object?>{},
    };
    final List<Object?> rawRequired = switch (schema.value['required']) {
      final List<Object?> list => list,
      _ => const <Object?>[],
    };
    final bool hasEnvelopeFields = schema.value.containsKey('allOf') ||
        rawProps.containsKey('id') ||
        rawProps.containsKey('component') ||
        rawRequired.contains('id') ||
        rawRequired.contains('component');
    final target = hasEnvelopeFields
        ? component
        : <String, Object?>{
            for (final MapEntry<String, Object?> entry in component.entries)
              if (entry.key != 'id' &&
                  entry.key != 'component' &&
                  entry.key != 'catalogId' &&
                  entry.key != 'metadata')
                entry.key: entry.value,
          };

    final List<ValidationError> errors = schema.validateSync(target);
    if (errors.isNotEmpty) {
      throw A2uiValidationError(
        "Component '${component['id']}' does not match the '$type' schema in "
        "catalog '${catalog.id}': "
        '${errors.map((e) => e.toErrorString()).join('; ')}',
        details: component,
      );
    }
  }

  /// Checks one function call's arguments against [catalog]'s schema for it.
  ///
  /// [name] is the function, [args] the arguments the call passes. As with
  /// [validateComponent], the caller decides which catalog the call belongs
  /// to: from v1.0 a call carries an optional `catalogId` of its own.
  ///
  /// From v1.0 the call's names, and those of every call nested in [args],
  /// are checked as [validateComponent] checks them. A nested call is judged
  /// as in a component that names no `catalogId`: one that names no
  /// `catalogId`, or names [catalog]'s id, is also checked against
  /// [catalog]'s function schemas.
  ///
  /// Throws [A2uiValidationError] if the catalog declares no such function,
  /// the arguments do not match its schema, or a name check fails.
  void validateFunction(String name, Map<String, Object?> args) {
    args = _jsonMap(args);
    if (protocolVersion.isAtLeast(A2uiProtocolVersion.v1_0)) {
      _checkCallIdentifiers(<String, Object?>{'@call': name, 'args': args});
      _checkNestedCalls(args);
    }
    _checkArgs(name, args);
  }

  /// Checks [args] against [catalog]'s argument schema for [name], leaving
  /// the calls nested in [args] unchecked.
  ///
  /// For `MessageProcessor`, which has already checked every call's names
  /// through [validateComponent] and checks each nested call against the
  /// catalog it resolves to. [componentId] names the component the call is
  /// nested in, for the error message.
  ///
  /// Throws [A2uiValidationError] if the catalog declares no such function or
  /// the arguments do not match its schema.
  @internal
  void validateFunctionArgs(
    String name,
    Map<String, Object?> args, {
    Object? componentId,
  }) =>
      _checkArgs(name, _jsonMap(args), componentId);

  /// Checks [args] against [catalog]'s argument schema for [name].
  ///
  /// [componentId], when given, names the component the call is nested in,
  /// for the error message.
  void _checkArgs(
    String name,
    Map<String, Object?> args, [
    Object? componentId,
  ]) {
    final where = componentId == null ? '' : "In component '$componentId': ";
    final Schema? schema = _resolvedFunctionSchemas[name];
    if (schema == null) {
      throw A2uiValidationError(
        "${where}Catalog '${catalog.id}' declares no function named '$name'.",
        details: args,
      );
    }

    final List<ValidationError> errors = schema.validateSync(args);
    if (errors.isNotEmpty) {
      throw A2uiValidationError(
        "${where}Call to '$name' does not match the argument schema in "
        "catalog '${catalog.id}': "
        '${errors.map((e) => e.toErrorString()).join('; ')}',
        details: args,
      );
    }
  }

  /// Checks a surface's theme against [catalog]'s theme schema.
  ///
  /// A catalog that declares no theme schema constrains nothing, so any theme
  /// passes. A null [theme] is the surface declaring none, which is always
  /// allowed.
  ///
  /// Throws [A2uiValidationError] if the theme does not match the schema.
  void validateTheme(Map<String, Object?>? theme) {
    final Schema? schema = catalog.themeSchema;
    if (schema == null || theme == null) return;
    theme = _jsonMap(theme);

    final List<ValidationError> errors = schema.validateSync(theme);
    if (errors.isNotEmpty) {
      throw A2uiValidationError(
        "Theme does not match the theme schema in catalog '${catalog.id}': "
        '${errors.map((e) => e.toErrorString()).join('; ')}',
        details: theme,
      );
    }
  }

  /// Checks, against [catalog], every v1.0 function call in [node] that runs
  /// in [catalog], however deeply it is nested, including inside the
  /// arguments of a call that runs elsewhere.
  ///
  /// [componentCatalogId] is the `catalogId` the component holding [node]
  /// names, or null, which means the component is in the surface default
  /// catalog; with [nestedCallRunsInCatalog] it decides which calls run in
  /// [catalog]. The others are left to [_checkCallIdentifiers]. A
  /// non-string `catalogId` is an error on any call.
  ///
  /// The component schema only checks a call's envelope, so these checks
  /// are what judge a call's function and arguments. Calls are checked
  /// innermost first, so the error names the call that is actually wrong
  /// rather than the call holding it. A system function belongs to no
  /// catalog: the schema and [_checkCallIdentifiers] check it, and its
  /// arguments are walked. [componentId], when given, names the component
  /// for the error message.
  void _checkNestedCalls(
    Object? node, {
    Object? componentId,
    Object? componentCatalogId,
  }) {
    if (node is List) {
      for (final Object? item in node) {
        _checkNestedCalls(
          item,
          componentId: componentId,
          componentCatalogId: componentCatalogId,
        );
      }
      return;
    }
    if (node is! Map) return;
    for (final Object? value in node.values) {
      _checkNestedCalls(
        value,
        componentId: componentId,
        componentCatalogId: componentCatalogId,
      );
    }
    final Object? name = node['@call'];
    if (name is! String || name.startsWith('@')) return;
    final subject = componentId == null
        ? "Function call '$name'"
        : "Function call '$name' in component '$componentId'";
    final Object? catalogId = node['catalogId'];
    if (catalogId != null && catalogId is! String) {
      throw A2uiValidationError(
        "$subject has a non-string 'catalogId'.",
        details: node,
      );
    }
    // A component that names no catalogId is taken to be in the surface
    // default catalog, where calls that name none run.
    if (!nestedCallRunsInCatalog(
      catalogId,
      catalog.id,
      catalogIsDefault: componentCatalogId == null,
    )) {
      return;
    }
    final Map<String, Object?> args = switch (node['args']) {
      null => const <String, Object?>{},
      final Map<String, Object?> map => map,
      _ => throw A2uiValidationError(
          "$subject has non-object 'args'.",
          details: node,
        ),
    };
    _checkArgs(name, args, componentId);
  }

  /// [value] with every map rebuilt as a `Map<String, Object?>` and every
  /// list as a `List<Object?>`, as JSON decoding yields them.
  ///
  /// `json_schema_builder` expects that shape; an untyped Dart literal such
  /// as `{'args': {}}` holds a `Map<dynamic, dynamic>` it would throw on.
  static Map<String, Object?> _jsonMap(Map<String, Object?> value) =>
      _jsonValue(value)! as Map<String, Object?>;

  static Object? _jsonValue(Object? value) => switch (value) {
        final Map<Object?, Object?> map => <String, Object?>{
            for (final MapEntry<Object?, Object?> entry in map.entries)
              '${entry.key}': _jsonValue(entry.value),
          },
        final List<Object?> list => <Object?>[
            for (final Object? item in list) _jsonValue(item),
          ],
        _ => value,
      };

  /// Which properties of [catalog]'s components hold child references.
  ///
  /// Graph checks span a whole surface, and from v1.0 a surface may hold
  /// components from several catalogs, so the walk itself belongs to
  /// `MessageProcessor`, which merges this map across the catalogs a surface
  /// draws on. Derived from [Catalog.refMap], the map the node resolver
  /// mounts children from.
  @internal
  Map<String, ComponentRefFields> get componentRefFields =>
      extractComponentRefFields(catalog);

  Map<String, Schema> get _resolvedComponentSchemas => _resolvedComponents ??= {
        for (final MapEntry<String, C> entry in catalog.components.entries)
          entry.key: _resolve(entry.value.schema),
      };

  Map<String, Schema> get _resolvedFunctionSchemas => _resolvedFunctions ??= {
        for (final MapEntry<String, F> entry in catalog.functions.entries)
          entry.key: _resolve(entry.value.argumentSchema),
      };

  Schema _resolve(Schema schema) => Schema.fromMap(
        resolveSchemaRefs(
          schema.value,
          _referenceDocument,
          commonTypes: commonTypesSchema,
        ),
      );

  /// The catalog document `$ref`s resolve against.
  ///
  /// From v1.0 a function call carries an optional `catalogId` and runs in
  /// the catalog it names, or else the surface's default catalog — not
  /// necessarily [catalog]. `common_types.json` reaches a catalog's own
  /// functions through `anyFunction` (the `@index` system function keeps its
  /// own branch beside it), so for v1.0 that union is replaced by
  /// [_anyV1FunctionCall], the `@call` envelope alone. Which calls run in
  /// [catalog] depends on the component holding them, which a schema can't
  /// see, so [_checkNestedCalls] checks those calls' functions and arguments
  /// in code, and [_checkCallIdentifiers] the names of every call. The
  /// catalog's `catalogSchema` states functions in the v0.9 `call` shape,
  /// which a v1.0 call would never match.
  Map<String, Object?> get _referenceDocument {
    final Map<String, Object?> document = catalog.catalogSchema;
    if (!protocolVersion.isAtLeast(A2uiProtocolVersion.v1_0)) return document;
    return <String, Object?>{
      ...document,
      r'$defs': <String, Object?>{
        ...?document[r'$defs'] as Map<String, Object?>?,
        'anyFunction': _anyV1FunctionCall,
      },
    };
  }

  /// A call's envelope with nothing checked against a catalog: any `@call`
  /// other than `@index`, with object `args`.
  static const Map<String, Object?> _anyV1FunctionCall = {
    'type': 'object',
    'properties': {
      '@call': {
        'type': 'string',
        'not': {'const': '@index'},
      },
      'args': {'type': 'object'},
    },
  };

  /// The one system function v1.0 defines in the reserved `@` namespace.
  static const String _indexFunction = '@index';

  /// Checks the names of every function call in [node], however deeply it is
  /// nested, without resolving the catalog the call runs in.
  ///
  /// Throws [A2uiValidationError] for a function name or argument name that
  /// is not an identifier, or for a system function other than `@index`.
  /// [componentId], when given, names the component [node] belongs to.
  static void _checkCallIdentifiers(Object? node, [Object? componentId]) {
    if (node is List) {
      for (final Object? item in node) {
        _checkCallIdentifiers(item, componentId);
      }
      return;
    }
    if (node is! Map) return;
    final Object? name = node['@call'];
    if (name is String) {
      final subject = componentId == null
          ? "Function call '$name'"
          : "Function call '$name' in component '$componentId'";
      if (name.startsWith('@')) {
        if (name != _indexFunction) {
          throw A2uiValidationError(
            "$subject names an unknown system function. The '@' namespace is "
            "reserved; only '$_indexFunction' is defined.",
            details: node,
          );
        }
      } else if (!isValidUax31Identifier(name)) {
        throw A2uiValidationError(
          '$subject does not name a valid UAX #31 identifier.',
          details: node,
        );
      }
      if (node['args'] case final Map<Object?, Object?> args) {
        for (final Object? argName in args.keys) {
          if (argName is! String || !isValidUax31Identifier(argName)) {
            throw A2uiValidationError(
              "$subject has argument '$argName', which is not a valid UAX #31 "
              'identifier.',
              details: node,
            );
          }
        }
      }
    }
    for (final Object? value in node.values) {
      _checkCallIdentifiers(value, componentId);
    }
  }
}
