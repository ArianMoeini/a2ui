# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import pytest

from a2ui.core import (
    A2uiCatalogError,
    A2uiErrorDetail,
    A2uiValidationError,
    CatalogApi,
    PayloadValidator,
)
from a2ui.core.basic_catalog import BasicCatalog, v0_8, v0_9, v1_0
from a2ui.schema import (
    VERSION_0_8,
    VERSION_0_9,
    VERSION_1_0,
    CatalogConfig,
    InMemoryCatalogProvider,
    remove_strict_validation,
)

BASIC_CATALOG_NAME = "basic"


def test_catalog_id_property():
    catalog_id = "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"
    config = CatalogConfig(
        name=BASIC_CATALOG_NAME,
        provider=InMemoryCatalogProvider({"catalogId": catalog_id}),
    )
    catalog = config.to_catalog(protocol_version=VERSION_0_8)
    assert catalog.catalog_id == catalog_id


def test_catalog_id_missing_raises_error():
    config = CatalogConfig(
        name=BASIC_CATALOG_NAME,
        provider=InMemoryCatalogProvider({}),  # No catalogId
    )
    with pytest.raises(A2uiCatalogError, match="missing 'catalogId'"):
        config.to_catalog(protocol_version=VERSION_0_8)


def test_catalog_config_requires_provider_or_catalog():
    with pytest.raises(TypeError, match="requires either 'provider' or 'catalog'"):
        CatalogConfig(name=BASIC_CATALOG_NAME)


def test_to_catalog_returns_configured_catalog_for_matching_version():
    catalog = BasicCatalog(VERSION_0_9)
    config = CatalogConfig.from_catalog(BASIC_CATALOG_NAME, catalog)

    assert config.to_catalog() is catalog
    # "0.9" and "v0.9" name the same version as the catalog's "v0.9".
    assert config.to_catalog(protocol_version="0.9") is catalog
    assert config.to_catalog(protocol_version="v0.9") is catalog


def test_to_catalog_reparses_for_another_version():
    catalog = BasicCatalog(VERSION_0_9)
    config = CatalogConfig.from_catalog(BASIC_CATALOG_NAME, catalog)

    reparsed = config.to_catalog(protocol_version=VERSION_0_8)

    assert reparsed is not catalog
    assert reparsed.protocol_version == VERSION_0_8
    assert reparsed.catalog_id == catalog.catalog_id
    assert set(reparsed.components) == set(catalog.components)


def test_to_catalog_with_modifiers_keeps_configured_catalog_version():
    catalog = BasicCatalog(VERSION_0_9)
    config = CatalogConfig.from_catalog(BASIC_CATALOG_NAME, catalog)

    modified = config.to_catalog(schema_modifiers=[remove_strict_validation])

    assert modified is not catalog
    assert modified.protocol_version == catalog.protocol_version


def test_resolve_examples_path_handling():
    from a2ui.schema.catalog import resolve_examples_path

    assert resolve_examples_path(None) is None
    assert resolve_examples_path("/absolute/examples") == "/absolute/examples"
    assert resolve_examples_path("file:///absolute/examples") == "/absolute/examples"

    with pytest.raises(ValueError, match="Unsupported examples URL scheme"):
        resolve_examples_path("https://a2ui.org/examples")


def test_catalog_config_from_path_schemes():
    # Test local path
    config = CatalogConfig.from_path(
        name="test_file", catalog_path="relative_path/to/catalog.json"
    )
    assert config.provider.path == "relative_path/to/catalog.json"

    # Test file:// scheme
    config = CatalogConfig.from_path(
        name="test_file", catalog_path="file:///absolute_path/to/catalog.json"
    )
    assert config.provider.path == "/absolute_path/to/catalog.json"

    # Test HTTP raises NotImplementedError
    with pytest.raises(NotImplementedError, match="HTTP support is coming soon."):
        CatalogConfig.from_path(
            name="test_http", catalog_path="http://a2ui.org/catalog.json"
        )

    # Test unsupported scheme raises ValueError
    with pytest.raises(ValueError, match="Unsupported catalog URL scheme"):
        CatalogConfig.from_path(
            name="test_ftp", catalog_path="ftp://a2ui.org/catalog.json"
        )


def test_basic_catalog_from_catalog_examples_path():
    # Test CatalogConfig.from_catalog with file:// scheme examples path
    config = CatalogConfig.from_catalog(
        "basic", BasicCatalog(VERSION_0_9), examples_path="file:///absolute/examples"
    )
    assert config.name == "basic"
    assert config.examples_path == "/absolute/examples"
    assert config.provider.load() == BasicCatalog(VERSION_0_9).catalog_schema


def test_basic_catalog_id_retrieval_methods():
    expected_0_8 = (
        "https://a2ui.org/specification/v0_8/standard_catalog_definition.json"
    )
    assert v0_8.BasicCatalog().catalog_id == expected_0_8
    assert BasicCatalog("0.8").catalog_id == expected_0_8
    assert BasicCatalog(VERSION_0_8).catalog_id == expected_0_8

    expected_0_9 = "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"
    assert v0_9.BasicCatalog().catalog_id == expected_0_9
    assert BasicCatalog("0.9").catalog_id == expected_0_9
    assert BasicCatalog(VERSION_0_9).catalog_id == expected_0_9

    expected_1_0 = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"
    assert v1_0.BasicCatalog().catalog_id == expected_1_0
    assert BasicCatalog("1.0").catalog_id == expected_1_0

    # BasicCatalog requires protocol_version with no implicit default.
    with pytest.raises(TypeError):
        BasicCatalog()  # type: ignore[call-arg]


def _v10_basic_json_catalog() -> CatalogApi:
    """Returns the v1.0 basic catalog parsed from its JSON schema."""
    return CatalogConfig(
        name=BASIC_CATALOG_NAME,
        provider=InMemoryCatalogProvider(v1_0.BasicCatalog().catalog_schema),
    ).to_catalog(protocol_version=VERSION_1_0)


def _validate_components(
    catalog: CatalogApi, components: dict | list[dict]
) -> list[A2uiErrorDetail]:
    """Collects the errors a direct PayloadValidator reports per component."""
    validator = PayloadValidator(catalog)
    errors: list[A2uiErrorDetail] = []
    for component in components if isinstance(components, list) else [components]:
        try:
            validator.validate_component(component)
        except A2uiValidationError as e:
            errors.extend(e.details)
    return errors


def _text_with(call: dict) -> dict:
    return {"id": "t1", "component": "Text", "text": call}


def test_v10_validate_components_checks_nested_calls():
    catalog = _v10_basic_json_catalog()

    assert not _validate_components(
        catalog, _text_with({"@call": "formatString", "args": {"value": "hi"}})
    )

    unknown = _validate_components(catalog, _text_with({"@call": "noSuchFn"}))
    assert any(e.code == "unrecognized_function" for e in unknown)

    nested_unknown = _validate_components(
        catalog,
        _text_with({
            "@call": "formatString",
            "args": {"value": {"@call": "noSuchFn", "args": {}}},
        }),
    )
    assert any(e.code == "unrecognized_function" for e in nested_unknown)

    extra_arg = _validate_components(
        catalog,
        _text_with({"@call": "formatString", "args": {"value": "hi", "bogus": 1}}),
    )
    assert any(
        e.code == "extra_field" and e.path == "components.t1.text" for e in extra_arg
    )

    missing_arg = _validate_components(
        catalog, _text_with({"@call": "formatString", "args": {}})
    )
    assert any(
        e.code == "missing_field" and e.path == "components.t1.text"
        for e in missing_arg
    )


def test_v10_validate_components_reports_one_located_error_per_bad_call():
    catalog = _v10_basic_json_catalog()

    errors = _validate_components(
        catalog,
        [
            {"id": "a", "component": "Text", "text": {"@call": "noSuchFn"}},
            {"id": "b", "component": "Text", "text": {"@call": "alsoNo"}},
        ],
    )

    assert [(e.path, e.code) for e in errors] == [
        ("components.a.text", "unrecognized_function"),
        ("components.b.text", "unrecognized_function"),
    ]


def test_v10_validate_components_accepts_call_naming_another_catalog():
    catalog = _v10_basic_json_catalog()

    assert not _validate_components(
        catalog,
        _text_with({
            "@call": "formatString",
            "catalogId": "https://example.com/other_catalog.json",
            "args": {"value": "hi"},
        }),
    )


def test_v10_basic_config_validate_components_judges_only_calls_it_runs():
    catalog = CatalogConfig.from_catalog(
        BASIC_CATALOG_NAME, BasicCatalog(VERSION_1_0)
    ).to_catalog(protocol_version=VERSION_1_0)

    # The call names another catalog, so basic cannot judge its function or
    # args, even though basic declares no `shout`.
    assert not _validate_components(
        catalog,
        _text_with({
            "@call": "shout",
            "catalogId": "https://example.com/other_catalog.json",
            "args": {"value": 3, "loud": True},
        }),
    )
    # An empty catalogId names a catalog too, so the same applies.
    assert not _validate_components(
        catalog, _text_with({"@call": "shout", "catalogId": "", "args": {}})
    )
    # Only identifier syntax is checked for such a call.
    bad_identifier = _validate_components(
        catalog,
        _text_with({
            "@call": "shout",
            "catalogId": "https://example.com/other_catalog.json",
            "args": {"bad-arg": 1},
        }),
    )
    assert [(e.path, e.code) for e in bad_identifier] == [
        ("components.t1.text.args.bad-arg", "invalid_identifier")
    ]

    # A call that names no catalogId or basic's own runs in basic.
    for call in (
        {"@call": "noSuchFn"},
        {"@call": "noSuchFn", "catalogId": catalog.catalog_id},
    ):
        errors = _validate_components(catalog, _text_with(call))
        assert [(e.path, e.code) for e in errors] == [
            ("components.t1.text", "unrecognized_function")
        ]


def test_v10_validate_components_rejects_bad_catalog_ids():
    catalog = _v10_basic_json_catalog()

    for bad_id in (0, False, 5):
        errors = _validate_components(
            catalog,
            _text_with({
                "@call": "formatString",
                "catalogId": bad_id,
                "args": {"value": "hi"},
            }),
        )
        assert ("components.t1.text.catalogId", "type_mismatch") in [
            (e.path, e.code) for e in errors
        ]
        assert not any(e.code == "unrecognized_function" for e in errors)

    index_errors = _validate_components(
        catalog, _text_with({"@call": "@index", "catalogId": catalog.catalog_id})
    )
    assert [(e.path, e.code) for e in index_errors] == [
        ("components.t1.text.catalogId", "extra_field")
    ]
