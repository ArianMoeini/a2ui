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

import 'package:meta/meta.dart';

import '../primitives/errors.dart';
import '../primitives/event_notifier.dart';
import '../validation/component_graph.dart';
import '../validation/component_refs.dart';
import '../validation/validation_config.dart';
import 'catalog.dart';

/// Represents the state model for an individual UI component.
///
/// [properties] holds the component's own properties only. The envelope
/// fields a component message carries, `id`, `component`, `catalogId` and
/// `metadata`, live in [id], [type], [catalogId] and [metadata] instead.
class ComponentModel {
  final String id;
  final String type;

  /// The catalog this component resolved to.
  ///
  /// A component belongs to exactly one catalog: the one its `catalogId`
  /// names, else the surface's default catalog. `MessageProcessor` resolves
  /// it once, when the component arrives, so nothing downstream re-derives
  /// it from the properties. A later update that resolves to a different
  /// catalog replaces the model rather than changing this.
  final Catalog<ComponentApi, FunctionImplementation> catalog;

  /// The `catalogId` this component names for itself, or null when it names
  /// none and so resolved to its surface's default catalog.
  ///
  /// This is what the payload wrote, kept so that [toJson] reads the same
  /// way; [catalog] is what it resolved to. An update that names the
  /// surface default explicitly, or stops naming it, resolves to the same
  /// [catalog] and changes only this. Updated with [properties], before
  /// [onUpdated] fires.
  String? catalogId;

  /// The `metadata` this component carries, or null when it carries none.
  ///
  /// Updated with [properties], before [onUpdated] fires, so a listener sees
  /// both from the same message.
  Map<String, Object?>? metadata;

  Map<String, dynamic> _properties;
  final _onUpdated = EventNotifier<ComponentModel>();

  /// Fires whenever the component's properties are updated.
  EventListenable<ComponentModel> get onUpdated => _onUpdated;

  /// Creates a component of [type] in [catalog].
  ///
  /// [initialProperties] are the component's own properties, without the
  /// envelope fields. [catalogId] is the `catalogId` the payload named, if
  /// any.
  ComponentModel(
    this.id,
    this.type,
    Map<String, dynamic> initialProperties, {
    required this.catalog,
    this.catalogId,
    this.metadata,
  }) : _properties = Map.from(initialProperties);

  /// The current properties of the component.
  Map<String, dynamic> get properties => _properties;

  set properties(Map<String, dynamic> newProperties) {
    _properties = Map.from(newProperties);
    _onUpdated.emit(this);
  }

  /// Disposes of the component and its resources.
  void dispose() {
    _onUpdated.dispose();
  }

  /// Returns the component as the message that would create it.
  ///
  /// Emits `catalogId` only when the payload named one. A component that
  /// resolved to the surface default without naming it is not given one: the
  /// object then reads the same way the payload did, and resolves to the same
  /// [catalog] on that surface.
  Map<String, dynamic> toJson() {
    return {
      ..._properties,
      'id': id,
      'component': type,
      if (catalogId != null) 'catalogId': catalogId,
      if (metadata != null) 'metadata': metadata,
    };
  }
}

/// Manages the collection of components for a specific surface.
///
/// The graph queries ([getChildIds], [detectCycles], [validateTopology],
/// [validateReferences] and [validateComponentsUpdate]) find a component's
/// child references through the reference properties its own
/// [ComponentModel.catalog] declares, so a surface whose components come from
/// several catalogs, or that has no default catalog, is walked correctly. The
/// `catalog` passed to the constructor is only used to read the entries of an
/// update passed to [validateComponentsUpdate].
class SurfaceComponentsModel {
  final Map<String, ComponentModel> _components = {};
  final _onCreated = EventNotifier<ComponentModel>();
  final _onDeleted = EventNotifier<String>();

  /// The catalog [validateComponentsUpdate] reads new entries through.
  final Catalog<ComponentApi, FunctionApi>? _catalog;

  /// Creates an empty model. [catalog] is the catalog the entries passed to
  /// [validateComponentsUpdate] are read through, normally the surface's
  /// default catalog; see there.
  SurfaceComponentsModel({Catalog<ComponentApi, FunctionApi>? catalog})
      : _catalog = catalog;

  /// Fires when a new component is added to the model.
  EventListenable<ComponentModel> get onCreated => _onCreated;

  /// Fires when a component is removed, providing the ID of the deleted
  /// component.
  EventListenable<String> get onDeleted => _onDeleted;

  /// Retrieves a component by its ID.
  ComponentModel? get(String id) => _components[id];

  /// Returns an iterator over the components in the model.
  Iterable<ComponentModel> get all => _components.values;

  /// Every component in the model, in insertion order.
  List<ComponentModel> getAll() => _components.values.toList();

  /// Whether the model holds a component with [id].
  bool has(String id) => _components.containsKey(id);

  /// How many components the model holds.
  int get size => _components.length;

  /// The components keyed by id, in insertion order.
  Iterable<MapEntry<String, ComponentModel>> get entries => _components.entries;

  /// The component ids, in insertion order.
  Iterable<String> get keys => _components.keys;

  /// The components, in insertion order.
  Iterable<ComponentModel> get values => _components.values;

  /// Adds a component to the model.
  void addComponent(ComponentModel component) {
    if (_components.containsKey(component.id)) {
      throw A2uiStateError(
        "Component with id '${component.id}' already exists.",
      );
    }
    _components[component.id] = component;
    _onCreated.emit(component);
  }

  /// Removes a component from the model by its ID.
  void removeComponent(String id) {
    final ComponentModel? component = _components.remove(id);
    if (component != null) {
      component.dispose();
      _onDeleted.emit(id);
    }
  }

  /// The ids the component with [id] references as children, in property
  /// order, including ids the model does not hold.
  ///
  /// Empty when the model holds no component with [id].
  List<String> getChildIds(String id) => [
        for (final ComponentReference reference in _referencesOf(id))
          reference.id,
      ];

  Iterable<ComponentReference> _referencesOf(String id) {
    final ComponentModel? component = _components[id];
    if (component == null) return const <ComponentReference>[];
    return componentReferences(
      component.properties,
      _refFieldsOf(component.catalog, component.type),
    );
  }

  /// The reference properties [catalog] declares for [type], or null when
  /// [catalog] is null or declares none.
  static ComponentRefFields? _refFieldsOf(
    Catalog<ComponentApi, FunctionApi>? catalog,
    String type,
  ) =>
      catalog == null ? null : extractComponentRefFields(catalog)[type];

  /// Checks for self-references, cycles and over-deep chains, and returns the
  /// ids reachable from [rootId].
  ///
  /// When [allowMissingRoot] is true every component is a starting point and
  /// every id is returned. [maxDepth] defaults to 50.
  ///
  /// Throws [A2uiRecursionError] when a check fails.
  Set<String> detectCycles({
    String rootId = 'root',
    int? maxDepth,
    bool allowMissingRoot = false,
  }) =>
      detectComponentCycles(
        _components.keys.toSet(),
        _referencesOf,
        rootId: rootId,
        allowMissingRoot: allowMissingRoot,
        maxDepth: maxDepth,
      );

  /// Checks the model as a surface's component graph against [config].
  ///
  /// The root is [ValidationConfig.rootId], or `root` when that is null. An
  /// empty model passes.
  ///
  /// Throws [A2uiIntegrityError] for a missing root, a dangling reference or
  /// an unreachable component, and [A2uiRecursionError] for a
  /// self-reference, a cycle or an over-deep chain.
  void validateTopology([ValidationConfig config = ValidationConfig.strict]) =>
      checkComponentGraph(_components.keys.toSet(), _referencesOf, config);

  /// Runs [validateTopology] and returns the error it throws, if any, rather
  /// than throwing it.
  ///
  /// The checks stop at the first failure, so the list holds at most one
  /// error.
  List<A2uiValidationError> validateReferences([
    ValidationConfig config = ValidationConfig.strict,
  ]) {
    try {
      validateTopology(config);
    } on A2uiValidationError catch (error) {
      return [error];
    }
    return const [];
  }

  /// Checks the graph this model would hold with [components] applied,
  /// without changing the model.
  ///
  /// Each entry in [components] replaces the component with its id. An entry
  /// that omits `component` keeps the existing component's type, and its
  /// `catalogId` when it omits that too. A duplicate id within [components]
  /// is an error.
  ///
  /// An entry's references are read through the catalog it would belong to:
  /// the one its `catalogId` names, when the constructor's catalog or an
  /// existing component's has that id; the existing component's, for an
  /// entry that omits both `component` and `catalogId`; and otherwise the
  /// constructor's catalog. An entry whose catalog is none of those has no
  /// references.
  ///
  /// Throws [A2uiValidationError] for an entry with no id, or with no type and
  /// no existing component; otherwise throws as [validateTopology] does.
  void validateComponentsUpdate(
    List<Map<String, Object?>> components, [
    ValidationConfig config = ValidationConfig.strict,
  ]) =>
      checkComponentsUpdate(components, config, catalogOf: _catalogOfEntry);

  Catalog<ComponentApi, FunctionApi>? _catalogOfEntry(
    Map<String, Object?> entry,
  ) {
    final ComponentModel? existing = _components[entry['id']];
    switch (entry['catalogId']) {
      case final String catalogId:
        if (_catalog?.id == catalogId) return _catalog;
        for (final ComponentModel component in _components.values) {
          if (component.catalog.id == catalogId) return component.catalog;
        }
        return null;
      case null when entry['component'] == null && existing != null:
        return existing.catalog;
    }
    return _catalog;
  }

  /// [validateComponentsUpdate] with [catalogOf] deciding the catalog each
  /// entry's references are read through, for a caller that has resolved
  /// them, and [defaultRootId] as the root when [ValidationConfig.rootId] is
  /// null. Components the model already holds are read through their own
  /// [ComponentModel.catalog].
  @internal
  void checkComponentsUpdate(
    List<Map<String, Object?>> components,
    ValidationConfig config, {
    required Catalog<ComponentApi, FunctionApi>? Function(
      Map<String, Object?> entry,
    ) catalogOf,
    String defaultRootId = 'root',
  }) {
    checkDuplicateComponentIds(components);
    // Each component as the map its references are read from and the
    // reference properties of its type. Existing components lend their
    // properties map rather than a copy.
    final candidate = <String, (Map<String, Object?>, ComponentRefFields?)>{
      for (final MapEntry<String, ComponentModel> entry in _components.entries)
        entry.key: (
          entry.value.properties,
          _refFieldsOf(entry.value.catalog, entry.value.type),
        ),
    };
    for (final component in components) {
      final Object? id = component['id'];
      if (id is! String) {
        throw A2uiValidationError(
          "Component missing an 'id'.",
          details: component,
        );
      }
      final Object? type = component['component'];
      final ComponentModel? existing = _components[id];
      final String resolvedType;
      if (type is String) {
        resolvedType = type;
      } else if (existing != null) {
        resolvedType = existing.type;
      } else {
        throw A2uiValidationError(
          "Cannot create component $id without a 'component' type.",
          details: component,
        );
      }
      candidate[id] = (
        component,
        _refFieldsOf(catalogOf(component), resolvedType),
      );
    }
    checkComponentGraph(candidate.keys.toSet(), (String id) {
      final (Map<String, Object?> source, ComponentRefFields? fields) =
          candidate[id]!;
      return componentReferences(source, fields);
    }, config, defaultRootId: defaultRootId);
  }

  /// Disposes of the model and all its components.
  void dispose() {
    for (final ComponentModel component in _components.values) {
      component.dispose();
    }
    _components.clear();
    _onCreated.dispose();
    _onDeleted.dispose();
  }
}
