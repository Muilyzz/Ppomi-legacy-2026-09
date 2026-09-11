/**
 * Glossary: the ppomi-body is this package plus `ppomi-body-*` surfaces;
 * a driver is observation ("eye") plus actuation ("hand"); the ppomi-path is
 * the JSON catalog. Every driver name is defined or re-exported here so a
 * rename is one commit in one module. `driver-*` / `adapter-*` are legacy names.
 *
 * Drivers may be implemented sync or async: the runtime awaits every call. None of
 * them carries a device-approval input.
 */
import type { MaybePromise } from "./playbook.ts";
import type { StepDriver } from "./step-result.ts";

/** Which OS family a driver controls; derived from the one `StepDriver` union and copied onto every `StepResult.driver`. */
export type OsUiDriverKind = Exclude<StepDriver, "page">;

/** Native / system-chrome snapshot: screen texts and the focused control's text. */
export interface ScreenSnapshot {
  readonly title: string;
  readonly texts: readonly string[];
  readonly focused: string | null;
}

/**
 * Native / system-chrome driver port, bound to the runtime by `OsSurface`. Not in-page DOM.
 * `kind` is optional so existing drivers compile; a run without a known kind
 * (neither here nor `RuntimeOptions.driver`) returns an `invalid` result instead of running.
 */
export interface OsUiDriver {
  readonly kind?: OsUiDriverKind;
  readScreen(): MaybePromise<ScreenSnapshot>;
  focus(target: string): MaybePromise<void>;
  click(target: string): MaybePromise<void>;
  type(target: string, text: string): MaybePromise<void>;
  /** Hardware / gesture key (iPhone Mirroring `phone_key`). Optional: other OS ports omit it. */
  key?(name: string): MaybePromise<void>;
}

/** In-page snapshot: url, title, visible texts and the locators present. */
export interface PageSnapshot {
  readonly url: string;
  readonly title: string;
  readonly texts: readonly string[];
  readonly locators: readonly string[];
}

/** In-page web driver port, bound to the runtime by `PageSurface`. Not `OsUiDriver`. */
export interface BrowserPageDriver {
  readPage(): MaybePromise<PageSnapshot>;
  goto(url: string): MaybePromise<void>;
  click(locator: string): MaybePromise<void>;
  fill(locator: string, text: string): MaybePromise<void>;
  waitFor(locator: string): MaybePromise<void>;
}

/** @deprecated Renamed to `OsUiDriver` (#22 glossary). */
export type OsAdapter = OsUiDriver;
/** @deprecated Renamed to `OsUiDriverKind` (#22 glossary). */
export type OsAdapterKind = OsUiDriverKind;
/** @deprecated Renamed to `BrowserPageDriver` (#22 glossary). */
export type BrowserPageAdapter = BrowserPageDriver;

export { OsSurface, type OsRef } from "./os-surface.ts";
export { PageSurface, navigationRefusal, publicUrl, type PageRef } from "./page-surface.ts";
