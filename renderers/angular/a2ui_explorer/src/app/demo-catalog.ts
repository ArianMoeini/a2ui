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

import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  Injectable,
  Injector,
  effect,
  inject,
} from '@angular/core';
import {
  A2uiRendererService,
  AngularCatalog,
  type AngularComponentImplementation,
  BASIC_COMPONENTS,
  BASIC_FUNCTIONS,
  CatalogComponent,
  MarkdownRenderer,
} from '@a2ui/angular/v0_9';
import {IFRAME_CATALOG_ID, iframeCatalog} from '@a2ui/catalog-iframe';
import {MCP_CATALOG_ID, mcpCatalog} from '@a2ui/catalog-mcp/v1_0';
import {type ComponentApi, ComponentContext} from '@a2ui/web_core/v0_9';
import {setMarkdownRenderer} from '@a2ui/web_core/v0_9/basic_catalog';
import {
  isWebComponentImplementation,
  registerUniversalElement,
  type WebComponentImplementation,
} from '@a2ui/web_core/v0_9/universal';
import {basicCatalog as basicCatalogV10} from '@a2ui/web_core/v1_0';
import {customSliderComponentDeclaration} from './custom-slider.component';
import {customGridComponentDeclaration} from './custom-grid.component';

interface UniversalHostElement extends HTMLElement {
  context?: ComponentContext;
  injector?: Injector;
}

/**
 * Fallback Angular component host that mounts universal Web Component catalog entries
 * even when `useUniversalComponents` is false on the Angular renderer.
 */
@Component({
  selector: 'a2ui-universal-demo-host',
  standalone: true,
  template: '',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class UniversalDemoHostComponent extends CatalogComponent<ComponentApi> {
  private readonly elementRef = inject(ElementRef<HTMLElement>);
  private readonly rendererService = inject(A2uiRendererService);
  private readonly injector = inject(Injector);
  private mountedEl: UniversalHostElement | null = null;

  constructor() {
    super();
    const markdownRenderer = this.injector.get(MarkdownRenderer, null);
    if (markdownRenderer) {
      setMarkdownRenderer((markdown, options) => markdownRenderer.render(markdown, options));
    }
    effect(() => {
      const surfaceId = this.surfaceId();
      const componentId = this.componentId();
      const dataContextPath = this.dataContextPath();
      const surface = this.rendererService.surfaceGroup?.getSurface(surfaceId);
      const compModel = surface?.componentsModel.get(componentId);
      const impl = compModel ? surface?.defaultCatalog.components.get(compModel.type) : undefined;
      if (!surface || !componentId || !impl || !isWebComponentImplementation(impl)) {
        return;
      }
      registerUniversalElement(impl);
      if (!this.mountedEl || this.mountedEl.tagName.toLowerCase() !== impl.tagName.toLowerCase()) {
        this.mountedEl?.remove();
        this.mountedEl = document.createElement(impl.tagName) as UniversalHostElement;
        this.elementRef.nativeElement.appendChild(this.mountedEl);
      }
      this.mountedEl.injector = this.injector;
      this.mountedEl.context = new ComponentContext(surface, componentId, dataContextPath);
    });
  }
}

function toUniversalDemoComponent(
  impl: WebComponentImplementation,
): AngularComponentImplementation {
  const entry: AngularComponentImplementation & WebComponentImplementation = {
    ...impl,
    component: UniversalDemoHostComponent,
  };
  return entry;
}

/**
 * A catalog specific to the demo, extending the basic catalog with custom components.
 */
@Injectable({
  providedIn: 'root',
})
export class DemoCatalog extends AngularCatalog {
  constructor() {
    super(
      'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json',
      '0.9',
      [...BASIC_COMPONENTS, customSliderComponentDeclaration, customGridComponentDeclaration],
      BASIC_FUNCTIONS,
    );
  }
}

/**
 * Creates additional v1.0 catalogs registered in the Angular explorer.
 */
export function createDemoCatalogs(): AngularCatalog[] {
  const iframeDemoCatalog = new AngularCatalog(
    IFRAME_CATALOG_ID,
    '1.0',
    [...basicCatalogV10.components.values(), ...iframeCatalog.components.values()].map(
      toUniversalDemoComponent,
    ),
    [...basicCatalogV10.functions.values()],
    basicCatalogV10.themeSchema,
  );
  const mcpDemoCatalog = new AngularCatalog(
    MCP_CATALOG_ID,
    '1.0',
    [...basicCatalogV10.components.values(), ...mcpCatalog.components.values()].map(
      toUniversalDemoComponent,
    ),
    [...basicCatalogV10.functions.values(), ...mcpCatalog.functions.values()],
    basicCatalogV10.themeSchema,
  );
  return [iframeDemoCatalog, mcpDemoCatalog];
}
