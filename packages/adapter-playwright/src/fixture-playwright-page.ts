import type { PageSnapshot } from "../../playbook-runtime/src/index.ts";
import type {
  PlaywrightPageNode,
  PlaywrightPageToolName,
  PlaywrightPageTools,
} from "./playwright-page-tools.ts";
import { PlaywrightPageError } from "./playwright-page-tools.ts";

export interface FixturePlaywrightNode {
  readonly locator: string;
  readonly text: string;
  readonly clickable: boolean;
  readonly fillable: boolean;
  readonly visible?: boolean;
}

export interface FixturePlaywrightDocument {
  readonly url: string;
  readonly title: string;
  readonly nodes: readonly FixturePlaywrightNode[];
}

export type FixturePlaywrightCall =
  | { readonly name: "goto"; readonly args: { readonly url: string } }
  | { readonly name: "click"; readonly args: { readonly locator: string } }
  | { readonly name: "fill"; readonly args: { readonly locator: string; readonly text: string } }
  | { readonly name: "waitFor"; readonly args: { readonly locator: string } }
  | { readonly name: "readPage"; readonly args: Record<string, never> };

/** In-memory stand-in for a Playwright page. No Chromium, no Vercel browser. */
export class FixturePlaywrightPage implements PlaywrightPageTools {
  readonly calls: FixturePlaywrightCall[] = [];
  private readonly documents: readonly FixturePlaywrightDocument[];
  private current: FixturePlaywrightDocument;
  private nodes: PlaywrightPageNode[] = [];

  constructor(documents: readonly FixturePlaywrightDocument[]) {
    if (documents.length === 0) throw new PlaywrightPageError("empty_fixture");
    this.documents = documents;
    this.current = documents[0]!;
    this.nodes = withVisible(this.current.nodes);
  }

  goto(args: { url: string }): { url: string } {
    this.calls.push({ name: "goto", args: { url: args.url } });
    const next = this.documents.find(document => document.url === args.url);
    if (next === undefined) throw new PlaywrightPageError("page_not_found", `page not found: ${args.url}`);
    this.current = next;
    this.nodes = withVisible(next.nodes);
    return { url: next.url };
  }

  click(args: { locator: string }): { clicked: boolean } {
    this.calls.push({ name: "click", args: { locator: args.locator } });
    const node = requireNode(this.nodes, args.locator, "clickable");
    if (!node.visible || !node.clickable) throw new PlaywrightPageError("locator_not_clickable");
    return { clicked: true };
  }

  fill(args: { locator: string; text: string }): { filled: boolean } {
    this.calls.push({ name: "fill", args: { locator: args.locator, text: args.text } });
    const node = requireNode(this.nodes, args.locator, "fillable");
    if (!node.visible || !node.fillable) throw new PlaywrightPageError("locator_not_fillable");
    return { filled: true };
  }

  waitFor(args: { locator: string }): { visible: boolean } {
    this.calls.push({ name: "waitFor", args: { locator: args.locator } });
    const node = this.nodes.find(item => item.locator === args.locator);
    if (node === undefined || !node.visible) {
      throw new PlaywrightPageError("locator_not_visible", `locator not visible: ${args.locator}`);
    }
    return { visible: true };
  }

  readPage(): PageSnapshot {
    this.calls.push({ name: "readPage", args: {} });
    const visible = this.nodes.filter(node => node.visible);
    return {
      url: this.current.url,
      title: this.current.title,
      texts: uniqueTexts([this.current.title, ...visible.map(node => node.text)]),
      locators: visible.map(node => node.locator),
    };
  }
}

export function fixtureToolNames(calls: readonly FixturePlaywrightCall[]): PlaywrightPageToolName[] {
  return calls.map(call => call.name);
}

function withVisible(nodes: readonly FixturePlaywrightNode[]): PlaywrightPageNode[] {
  return nodes.map(node => ({
    locator: node.locator,
    text: node.text,
    clickable: node.clickable,
    fillable: node.fillable,
    visible: node.visible ?? true,
  }));
}

function requireNode(
  nodes: readonly PlaywrightPageNode[],
  locator: string,
  need: "clickable" | "fillable",
): PlaywrightPageNode {
  const matches = nodes.filter(node => node.locator === locator);
  if (matches.length === 0) throw new PlaywrightPageError("locator_not_on_page", `locator not on page: ${locator}`);
  if (matches.length !== 1) throw new PlaywrightPageError("ambiguous_locator", `ambiguous locator: ${locator}`);
  const node = matches[0]!;
  if (need === "clickable" ? !node.clickable : !node.fillable) {
    throw new PlaywrightPageError("protected_action", `locator not ${need}: ${locator}`);
  }
  return node;
}

function uniqueTexts(values: readonly string[]): string[] {
  const texts: string[] = [];
  for (const value of values) {
    const text = value.trim();
    if (text.length === 0 || texts.includes(text)) continue;
    texts.push(text);
  }
  return texts;
}
