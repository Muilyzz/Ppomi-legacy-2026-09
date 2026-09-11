/**
 * Glossary (#22): the ppomi-body is `playbook-runtime` plus the `driver-*`
 * packages; a driver is observation ("eye") plus actuation ("hand"); the
 * ppomi-path is `playbook-*` content. Every driver name is defined or re-exported
 * here so a rename is one commit in one module.
 *
 * Drivers may be implemented sync or async: the runtime awaits every call. None of
 * them carries a device-approval input.
 */
import type { MaybePromise } from "./playbook.ts";

/** Which OS family a driver controls; copied onto every `StepResult.adapter` (#17 keeps that field name). */
export type OsUiDriverKind = "os-windows" | "os-macos" | "phone";

/** Native / system-chrome snapshot: screen texts and the focused control's text. */
export interface ScreenSnapshot {
  readonly title: string;
  readonly texts: readonly string[];
  readonly focused: string | null;
}

/** Native / system-chrome driver port, bound to the runtime by `OsSurface`. Not in-page DOM. */
export interface OsUiDriver {
  readonly kind: OsUiDriverKind;
  readScreen(): MaybePromise<ScreenSnapshot>;
  focus(target: string): MaybePromise<void>;
  click(target: string): MaybePromise<void>;
  type(target: string, text: string): MaybePromise<void>;
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
