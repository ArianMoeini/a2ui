/*
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import {IFRAME_CATALOG_ID, iframeCatalog} from '@a2ui/catalog-iframe';
import {MCP_CATALOG_ID, mcpCatalog} from '@a2ui/catalog-mcp/v1_0';
import {type ReactCatalogComponent} from '@a2ui/react/v0_9';
import {Catalog} from '@a2ui/web_core/v0_9';
import {basicCatalog, BASIC_FUNCTIONS} from '@a2ui/web_core/v0_9/basic_catalog';
import {basicCatalog as basicCatalogV10} from '@a2ui/web_core/v1_0';
import {customSliderComponent} from './custom-slider';
import {customGridComponent} from './custom-grid';

/**
 * A catalog specific to the React demo explorer, extending the basic catalog
 * with custom components.
 */
export const demoCatalog = new Catalog(
  basicCatalog.id,
  '0.9',
  [...basicCatalog.components.values(), customSliderComponent, customGridComponent],
  BASIC_FUNCTIONS,
);

/**
 * Additional v1.0 catalogs registered in the React explorer.
 */
export function createDemoCatalogs(): Array<Catalog<ReactCatalogComponent>> {
  const iframeDemoCatalog = new Catalog<ReactCatalogComponent>(
    IFRAME_CATALOG_ID,
    '1.0',
    [...basicCatalogV10.components.values(), ...iframeCatalog.components.values()],
    [...basicCatalogV10.functions.values()],
    basicCatalogV10.themeSchema,
  );
  const mcpDemoCatalog = new Catalog<ReactCatalogComponent>(
    MCP_CATALOG_ID,
    '1.0',
    [...basicCatalogV10.components.values(), ...mcpCatalog.components.values()],
    [...basicCatalogV10.functions.values(), ...mcpCatalog.functions.values()],
    basicCatalogV10.themeSchema,
  );
  return [iframeDemoCatalog, mcpDemoCatalog];
}
