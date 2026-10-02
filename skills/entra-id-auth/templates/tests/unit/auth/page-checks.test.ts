/**
 * Control C26: every file under app/ that serves a gated path checks the
 * person itself, as the first thing it does.
 *
 *  - page, layout, template and default files: the default export starts with
 *    `await requirePagePerson()` or `await requireAdministratorPage()`, and so
 *    does generateMetadata when the file exports it.
 *  - metadata image and sitemap files (opengraph-image, twitter-image, icon,
 *    apple-icon, sitemap): the same, and so do generateImageMetadata and
 *    generateSitemaps when the file exports them, because they can render
 *    per-record data.
 *  - route files (route.ts, .js, .tsx, .jsx): every exported method (GET,
 *    HEAD, POST, PUT, PATCH, DELETE, OPTIONS) starts with
 *    `await requireCurrentPerson()` or `await requireAdministrator()`, each on
 *    its own.
 *  - server actions: in a file whose first line is "use server", every
 *    exported function starts with `await requireCurrentPerson()` or
 *    `await requireAdministrator()`, the route rule, try form included. An
 *    action written inside a gated page or route (a function whose body starts
 *    with "use server") does the same on the line after that directive: Next
 *    runs an action on its own, without the page's check.
 *  - an MDX page (page.mdx, page.md) fails: it cannot check the person. Import
 *    its content into a page.tsx that checks first.
 *
 * "Starts with" means the first statement of the function body is that call,
 * awaited, alone or as a `const x = await ...` line, and the function called
 * is the one imported from lib/auth/current-person. In a page the call sits
 * outside any try: redirect() works by throwing, so a catch would swallow it.
 * In a route the call may be the first statement inside a leading try, the
 * pattern examples/route-handler.ts teaches, only when nothing follows the
 * try, every catch ends in a return or a throw, and no finally returns.
 * Each file is parsed with the TypeScript compiler, so a comment never
 * counts, and a default export written as a function, an arrow, a const
 * exported later, `export { X as default }` or a wrapped function is found
 * whatever its form. A form the check cannot read (a re-export, `export *`,
 * a class) fails: write the function in the file.
 *
 * A gated path is any path isPublicPath() refuses (route-access.ts). A page,
 * route or metadata file is gated when its folder's path is. A server action
 * is not served on its folder's path but on the pages that use its file, so
 * any other script is read for actions (a "use server" file: every exported
 * function; any other file: an action written inside it) when a signed-in page
 * uses it: the file's folder path is gated, a gated page sits in or below its
 * folder, or a gated file imports it, directly or through other files and
 * components anywhere in the source folder, outside app/ too (relative paths,
 * "@/" and ".js" specifiers followed). So app/actions.ts and (app)/actions.ts
 * are read even with "/" public; only a file used by public pages alone
 * (sign-in/actions.ts) is skipped, and it must do nothing a stranger may not.
 * The same holds for an action only the root layout, template or default uses:
 * those files also serve /sign-in, so it is not read and must be safe for a
 * stranger. A
 * layout, template or default is gated when any page it wraps is: every page
 * in its folder and below (for a default directly in an @slot folder, every
 * page under the layout that renders the slot). So a route group's layout over
 * public pages only needs no check, and one over a public page and a gated one
 * needs it (move the public pages into a group of their own). A wrapper with
 * no page under it is gated when its own folder's path is. The files allowed
 * to skip are the root-level wrappers (app/layout.*, app/template.*,
 * app/default.*) and root-level metadata files (app/icon.* and the like),
 * which also serve /sign-in and so must show nothing private: a root wrapper
 * that needs the person moves into (app)/. Not read, with the proxy as their
 * only gate: not-found, error, loading and global-error files (static by
 * convention), robots and manifest files (root only, site-wide), a Pages
 * Router pages/ folder, an action file no page imports (check those by eye),
 * and a public-only action file as above. A dynamic import with a computed
 * name is not followed.
 *
 * Why every page and not only the layout: Next renders a layout and its page
 * in parallel. When the layout redirects, a page with no check of its own is
 * still rendered and sent in the body of the 307. The proxy reads the person
 * too; this keeps a second check if the proxy is ever changed or skipped.
 */
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

import ts from "typescript";
import { afterAll, describe, expect, it } from "vitest";

import { isPublicPath } from "@/lib/auth/route-access";

const PAGE_FILE = /^(page|layout|template|default)\.(tsx|jsx|ts|js)$/;
const METADATA_FILE = /^(opengraph-image|twitter-image|icon|apple-icon|sitemap)\.(tsx|jsx|ts|js)$/;
const MDX_PAGE = /^page\.mdx?$/;
const HANDLER_FILE = /^route\.(tsx|jsx|ts|js)$/;
/** Files that wrap the pages in their folder and below, rather than serving one path themselves. */
const WRAPPER_FILE = /^(layout|template|default)\.(tsx|jsx|ts|js)$/;
/** The pages a wrapper can wrap. */
const PAGE_ONLY = /^page\.(tsx|jsx|ts|js|mdx|md)$/;
/** Any script file, read only when its first line is "use server". */
const SCRIPT_FILE = /\.(m|c)?(tsx?|jsx?)$/;
/** Files at the root of app/ that also serve /sign-in: they must show nothing private, and cannot check. */
const ROOT_EXEMPT = /^(layout|template|default|opengraph-image|twitter-image|icon|apple-icon|sitemap)\./;
/** Named exports that render on their own, beside the default export, and so need their own check. */
const SIDE_EXPORTS = ["generateMetadata", "generateImageMetadata", "generateSitemaps"];
const PAGE_CHECKS = new Set(["requirePagePerson", "requireAdministratorPage"]);
const HANDLER_CHECKS = new Set(["requireCurrentPerson", "requireAdministrator"]);
const HTTP_METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"];
/** "@/lib/auth/current-person", "../../lib/auth/current-person" and the like. */
const CHECK_MODULE = /(?:^@\/|\/)lib\/auth\/current-person(?:\.[cm]?[jt]sx?)?$/;

/** The URL path a folder under app/ serves: route groups "(x)" and slots "@x" add nothing. */
function routeOf(appRelativeDir: string): string {
  const segments = appRelativeDir
    .split(/[\\/]/)
    .filter((s) => s !== "" && s !== "." && !/^\([^.)][^)]*\)$/.test(s) && !s.startsWith("@"));
  return `/${segments.join("/")}`;
}

type Fn = ts.FunctionDeclaration | ts.FunctionExpression | ts.ArrowFunction | ts.MethodDeclaration;
/** found: the file exports the name. fn: the function behind it, when the check can read it. */
type Export = { found: boolean; fn?: Fn };

const hasModifier = (node: ts.Node, kind: ts.SyntaxKind) =>
  ts.canHaveModifiers(node) && (ts.getModifiers(node) ?? []).some((m) => m.kind === kind);

/** Local names bound to the checks from lib/auth/current-person: plain, aliased or through `import * as`. */
function checkImports(sf: ts.SourceFile): { named: Map<string, string>; namespaces: Set<string> } {
  const named = new Map<string, string>();
  const namespaces = new Set<string>();
  for (const st of sf.statements) {
    if (!ts.isImportDeclaration(st) || !ts.isStringLiteral(st.moduleSpecifier)) continue;
    if (!CHECK_MODULE.test(st.moduleSpecifier.text) || !st.importClause || st.importClause.isTypeOnly) continue;
    const bindings = st.importClause.namedBindings;
    if (bindings && ts.isNamespaceImport(bindings)) namespaces.add(bindings.name.text);
    if (bindings && ts.isNamedImports(bindings)) {
      for (const el of bindings.elements) {
        if (!el.isTypeOnly) named.set(el.name.text, (el.propertyName ?? el.name).text);
      }
    }
  }
  return { named, namespaces };
}

class Reader {
  private readonly imports: ReturnType<typeof checkImports>;

  constructor(private readonly sf: ts.SourceFile) {
    this.imports = checkImports(sf);
  }

  get sourceFile(): ts.SourceFile {
    return this.sf;
  }

  static parse(file: string, source: string): Reader {
    const kind = file.endsWith(".tsx") ? ts.ScriptKind.TSX : file.endsWith(".ts") ? ts.ScriptKind.TS : ts.ScriptKind.JSX;
    return new Reader(ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, kind));
  }

  /** A directive ("use client", "use server") at the top of the file. */
  hasDirective(name: string): boolean {
    return directives(this.sf.statements).includes(name);
  }

  isClient(): boolean {
    return this.hasDirective("use client");
  }

  /** Every name the file exports, "default" included. */
  exportedNames(): string[] {
    const names = new Set<string>();
    for (const st of this.sf.statements) {
      if (ts.isFunctionDeclaration(st) && hasModifier(st, ts.SyntaxKind.ExportKeyword)) {
        names.add(hasModifier(st, ts.SyntaxKind.DefaultKeyword) ? "default" : (st.name?.text ?? "default"));
      }
      if (ts.isClassDeclaration(st) && hasModifier(st, ts.SyntaxKind.ExportKeyword)) {
        names.add(hasModifier(st, ts.SyntaxKind.DefaultKeyword) ? "default" : (st.name?.text ?? "default"));
      }
      if (ts.isExportAssignment(st) && !st.isExportEquals) names.add("default");
      if (ts.isVariableStatement(st) && hasModifier(st, ts.SyntaxKind.ExportKeyword)) {
        for (const d of st.declarationList.declarations) {
          if (ts.isIdentifier(d.name)) names.add(d.name.text);
          else for (const e of d.name.elements) if (ts.isBindingElement(e) && ts.isIdentifier(e.name)) names.add(e.name.text);
        }
      }
      if (ts.isExportDeclaration(st) && !st.isTypeOnly && st.exportClause && ts.isNamedExports(st.exportClause)) {
        for (const el of st.exportClause.elements) if (!el.isTypeOnly) names.add(el.name.text);
      }
    }
    return [...names];
  }

  /** Server actions written inline: functions whose body starts with a "use server" directive. */
  inlineActions(): Fn[] {
    const found: Fn[] = [];
    const visit = (n: ts.Node) => {
      if ((ts.isFunctionDeclaration(n) || ts.isFunctionExpression(n) || ts.isArrowFunction(n) || ts.isMethodDeclaration(n)) && n.body && ts.isBlock(n.body)) {
        if (directives(n.body.statements).includes("use server")) found.push(n);
      }
      ts.forEachChild(n, visit);
    };
    ts.forEachChild(this.sf, visit);
    return found;
  }

  hasStarExport(): boolean {
    return this.sf.statements.some((st) => ts.isExportDeclaration(st) && !st.exportClause);
  }

  /** The function an expression stands for: unwraps parentheses, casts, a wrapper call and local names. */
  private resolve(node: ts.Node | undefined, depth = 0): Fn | undefined {
    if (!node || depth > 8) return undefined;
    if (ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node)) return node;
    if (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isSatisfiesExpression(node) || ts.isNonNullExpression(node) || ts.isTypeAssertionExpression(node)) {
      return this.resolve(node.expression, depth + 1);
    }
    // A wrapped function, such as wrap(async function Page() {...}): the function passed in.
    if (ts.isCallExpression(node)) {
      const inner = node.arguments.map((a) => this.resolve(a, depth + 1)).filter((f): f is Fn => f !== undefined);
      return inner.length === 1 ? inner[0] : undefined;
    }
    if (ts.isIdentifier(node)) return this.resolve(this.localDeclaration(node.text), depth + 1);
    return undefined;
  }

  /** What a top-level local name is bound to: a function declaration or a variable's initializer. */
  private localDeclaration(name: string): ts.Node | undefined {
    for (const st of this.sf.statements) {
      if (ts.isFunctionDeclaration(st) && st.name?.text === name) return st;
      if (ts.isVariableStatement(st)) {
        for (const d of st.declarationList.declarations) {
          if (ts.isIdentifier(d.name) && d.name.text === name) return d.initializer;
        }
      }
    }
    return undefined;
  }

  defaultExport(): Export {
    for (const st of this.sf.statements) {
      if (ts.isFunctionDeclaration(st) && hasModifier(st, ts.SyntaxKind.ExportKeyword) && hasModifier(st, ts.SyntaxKind.DefaultKeyword)) {
        return { found: true, fn: st };
      }
      if (ts.isClassDeclaration(st) && hasModifier(st, ts.SyntaxKind.DefaultKeyword)) return { found: true };
      if (ts.isExportAssignment(st) && !st.isExportEquals) return { found: true, fn: this.resolve(st.expression) };
    }
    return this.namedExport("default");
  }

  namedExport(name: string): Export {
    for (const st of this.sf.statements) {
      if (ts.isFunctionDeclaration(st) && st.name?.text === name && hasModifier(st, ts.SyntaxKind.ExportKeyword)) {
        return { found: true, fn: st };
      }
      if (ts.isVariableStatement(st) && hasModifier(st, ts.SyntaxKind.ExportKeyword)) {
        for (const d of st.declarationList.declarations) {
          if (ts.isIdentifier(d.name) && d.name.text === name) return { found: true, fn: this.resolve(d.initializer) };
          // export const { GET, POST } = something(): exported, but not readable here.
          if (!ts.isIdentifier(d.name) && d.name.elements.some((e) => ts.isBindingElement(e) && ts.isIdentifier(e.name) && e.name.text === name)) {
            return { found: true };
          }
        }
      }
      if (ts.isExportDeclaration(st) && !st.isTypeOnly && st.exportClause && ts.isNamedExports(st.exportClause)) {
        for (const el of st.exportClause.elements) {
          if (el.isTypeOnly || el.name.text !== name) continue;
          if (st.moduleSpecifier) return { found: true }; // a re-export from another file
          return { found: true, fn: this.resolve(this.localDeclaration((el.propertyName ?? el.name).text)) };
        }
      }
    }
    return { found: false };
  }

  /** `await check()`, where check is one of `allowed` imported from lib/auth/current-person. */
  private isCheckCall(expr: ts.Expression | undefined, allowed: Set<string>): boolean {
    while (expr && ts.isParenthesizedExpression(expr)) expr = expr.expression;
    if (!expr || !ts.isAwaitExpression(expr)) return false;
    let call: ts.Expression = expr.expression;
    while (ts.isParenthesizedExpression(call)) call = call.expression;
    if (!ts.isCallExpression(call)) return false;
    const callee = call.expression;
    if (ts.isIdentifier(callee)) return allowed.has(this.imports.named.get(callee.text) ?? "");
    if (ts.isPropertyAccessExpression(callee) && ts.isIdentifier(callee.expression)) {
      return this.imports.namespaces.has(callee.expression.text) && allowed.has(callee.name.text);
    }
    return false;
  }

  /**
   * The function's first statement is the check. allowTry (routes only): the
   * check may be the first statement inside a leading try that nothing
   * follows, whose every catch ends in a return or a throw and whose finally
   * never returns, so a failed check can never fall through to the code after.
   */
  startsWithCheck(fn: Fn | undefined, allowed: Set<string>, allowTry = false): boolean {
    if (!fn?.body || !ts.isBlock(fn.body)) return false; // an arrow with an expression body checks nothing first
    // Directives ("use server") are not statements that run: the check is the first line after them.
    const body = fn.body.statements;
    return this.listStartsWithCheck(body.slice(directives(body).length), allowed, allowTry, true);
  }

  /** last: nothing runs after this list once it finishes. */
  private listStartsWithCheck(list: readonly ts.Statement[], allowed: Set<string>, allowTry: boolean, last: boolean): boolean {
    const first = list[0];
    if (!first) return false;
    if (ts.isBlock(first)) return this.listStartsWithCheck(first.statements, allowed, allowTry, last && list.length === 1);
    if (ts.isTryStatement(first)) {
      if (!allowTry || !last || list.length !== 1) return false; // code after the try runs when a catch swallows
      if (first.catchClause && !endsInReturnOrThrow(first.catchClause.block)) return false;
      if (first.finallyBlock && containsReturn(first.finallyBlock)) return false;
      return this.listStartsWithCheck(first.tryBlock.statements, allowed, allowTry, true);
    }
    if (ts.isExpressionStatement(first)) return this.isCheckCall(first.expression, allowed);
    if (ts.isVariableStatement(first)) return this.isCheckCall(first.declarationList.declarations[0]?.initializer, allowed);
    return false;
  }
}

/** The directive prologue of a file or function body: its leading string-literal statements. */
function directives(list: readonly ts.Statement[]): string[] {
  const out: string[] = [];
  for (const st of list) {
    if (!ts.isExpressionStatement(st) || !ts.isStringLiteral(st.expression)) break;
    out.push(st.expression.text);
  }
  return out;
}

/** Control can never leave this statement by falling off its end: it returns a value or throws on every path. */
function endsInReturnOrThrow(st: ts.Statement | undefined): boolean {
  if (!st) return false;
  if (ts.isReturnStatement(st)) return st.expression !== undefined;
  if (ts.isThrowStatement(st)) return true;
  if (ts.isBlock(st)) return endsInReturnOrThrow(st.statements[st.statements.length - 1]);
  if (ts.isIfStatement(st)) return endsInReturnOrThrow(st.thenStatement) && endsInReturnOrThrow(st.elseStatement);
  return false;
}

/** A return anywhere in the block, not counting nested functions. */
function containsReturn(node: ts.Node): boolean {
  let found = false;
  const visit = (n: ts.Node) => {
    if (found || ts.isFunctionLike(n)) return;
    if (ts.isReturnStatement(n)) found = true;
    else ts.forEachChild(n, visit);
  };
  ts.forEachChild(node, visit);
  return found;
}

const PAGE_CALL = "await requirePagePerson()";
const HANDLER_CALL = "await requireCurrentPerson()";

/** Why a page, layout, template, default or metadata file fails the check, or null when it passes. */
function pageProblem(file: string, source: string): string | null {
  const r = Reader.parse(file, source);
  if (r.isClient()) return '"use client" file: it cannot check the person';
  if (r.hasStarExport()) return "export * cannot be read: export the component from this file";
  const inline = inlineActionProblem(r);
  if (inline) return inline;
  const main = r.defaultExport();
  if (!main.found) return "no default export";
  if (!main.fn) return "the default export is not a function this check can read (a re-export or a class)";
  if (!r.startsWithCheck(main.fn, PAGE_CHECKS)) return `the default export does not start with ${PAGE_CALL}`;
  // Metadata, image ids and sitemap ids render on their own: each needs its own check.
  for (const name of SIDE_EXPORTS) {
    const side = r.namedExport(name);
    if (side.found && !r.startsWithCheck(side.fn, PAGE_CHECKS)) return `${name} does not start with ${PAGE_CALL}`;
  }
  return null;
}

/** Why a route file fails the check, or null when every exported method checks first. */
function handlerProblem(file: string, source: string): string | null {
  const r = Reader.parse(file, source);
  if (r.hasStarExport()) return "export * cannot be read: export each method from this file";
  const inline = inlineActionProblem(r);
  if (inline) return inline;
  const unchecked = HTTP_METHODS.filter((m) => {
    const e = r.namedExport(m);
    return e.found && !r.startsWithCheck(e.fn, HANDLER_CHECKS, true);
  });
  return unchecked.length ? `${unchecked.join(", ")} does not start with ${HANDLER_CALL}` : null;
}

/** An inline server action that does not check first, or null. */
function inlineActionProblem(r: Reader): string | null {
  const bad = r.inlineActions().filter((fn) => !r.startsWithCheck(fn, HANDLER_CHECKS, true));
  return bad.length ? `a "use server" action written here does not start with ${HANDLER_CALL}` : null;
}

/** Why a "use server" file fails the check, or null when every exported action checks first. */
function actionProblem(file: string, source: string): string | null {
  const r = Reader.parse(file, source);
  if (r.hasStarExport()) return "export * cannot be read: export each action from this file";
  const unchecked = r.exportedNames().filter((name) => {
    const e = name === "default" ? r.defaultExport() : r.namedExport(name);
    return !r.startsWithCheck(e.fn, HANDLER_CHECKS, true);
  });
  return unchecked.length ? `server action ${unchecked.join(", ")} does not start with ${HANDLER_CALL}` : null;
}

type Problem = { file: string; why: string };

/** Every module a file names: import, export ... from, and import("...") with a plain string. */
function importSpecifiers(r: Reader): string[] {
  const out: string[] = [];
  const visit = (n: ts.Node) => {
    if ((ts.isImportDeclaration(n) || ts.isExportDeclaration(n)) && n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier)) {
      out.push(n.moduleSpecifier.text);
    }
    if (ts.isCallExpression(n) && n.expression.kind === ts.SyntaxKind.ImportKeyword && n.arguments[0] && ts.isStringLiteralLike(n.arguments[0])) {
      out.push(n.arguments[0].text);
    }
    ts.forEachChild(n, visit);
  };
  visit(r.sourceFile);
  return out;
}

/** The script file an import names (absolute path), when it is one of `known`; "@/" is the folder app/ sits in. */
function resolveImport(srcRoot: string, fromAbs: string, spec: string, known: Set<string>): string | undefined {
  let base: string;
  if (spec.startsWith("./") || spec.startsWith("../")) base = join(dirname(fromAbs), spec);
  else if (spec.startsWith("@/")) base = join(srcRoot, spec.slice(2));
  else return undefined;
  // "./actions.js" names actions.ts under TypeScript's ESM rules: try the extension swapped too.
  const swapped = base.replace(/\.(m|c)?jsx?$/, (_m, k: string | undefined) => `.${k ?? ""}ts`);
  const tries = [base, swapped, swapped + "x", ...["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"].flatMap((e) => [`${base}.${e}`, `${base}/index.${e}`])];
  return tries.find((t) => known.has(t));
}

/** Every script file under dir (node_modules, .next and dot folders left out). */
function scriptFilesUnder(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".next" || entry.name.startsWith(".")) continue;
      out.push(...scriptFilesUnder(join(dir, entry.name)));
    } else if (SCRIPT_FILE.test(entry.name)) out.push(join(dir, entry.name));
  }
  return out;
}

/** app-relative folder, with "/" separators and "" for app/ itself. */
const folderOf = (rel: string) => {
  const d = dirname(rel).split(sep).join("/");
  return d === "." ? "" : d;
};
const isUnder = (dir: string, scope: string) => scope === "" || dir === scope || dir.startsWith(`${scope}/`);

/**
 * Files under appDir that serve a gated path and do not check the person first,
 * relative to appDir. isPublic is isPublicPath() on a site; the tests pass
 * their own to try other PUBLIC_PATHS.
 */
function findProblems(appDir: string, isPublic: (path: string) => boolean = isPublicPath): Problem[] {
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else files.push(relative(appDir, full));
    }
  };
  walk(appDir);
  const gatedPath = (dir: string) => !isPublic(routeOf(dir));
  const pageDirs = files.filter((f) => PAGE_ONLY.test(basename(f))).map(folderOf);

  /** A layout, template or default is gated when a page it wraps is. */
  const wrapperGated = (dir: string, name: string) => {
    const parts = dir.split("/");
    const scope = name.startsWith("default.") && parts[parts.length - 1]?.startsWith("@") ? parts.slice(0, -1).join("/") : dir;
    const wrapped = pageDirs.filter((d) => isUnder(d, scope));
    return wrapped.length ? wrapped.some(gatedPath) : gatedPath(dir);
  };
  /** A folder whose own path is gated, or with a gated page in it or below. */
  const folderGated = (dir: string) => gatedPath(dir) || pageDirs.some((d) => isUnder(d, dir) && gatedPath(d));

  /**
   * Script files reached, through any chain of imports, from a file in a gated folder: an action there
   * runs on a gated page. The chain is followed through the whole source folder app/ sits in, so a shared
   * component outside app/ counts.
   */
  const srcRoot = basename(appDir) === "app" ? dirname(appDir) : appDir; // a fixture folder is scanned alone
  const known = new Set(scriptFilesUnder(srcRoot));
  const reached = new Set<string>();
  /** A file that is itself served on a gated path: a gated page, wrapper, handler or metadata file, or a script in a gated folder. */
  const servedGated = (rel: string) => {
    const name = basename(rel);
    const dir = folderOf(rel);
    if ((PAGE_FILE.test(name) || METADATA_FILE.test(name)) && dir === "" && ROOT_EXEMPT.test(name)) return false;
    return WRAPPER_FILE.test(name) ? wrapperGated(dir, name) : gatedPath(dir);
  };
  const queue = files.filter((rel) => SCRIPT_FILE.test(basename(rel)) && servedGated(rel)).map((rel) => join(appDir, rel));
  for (const f of queue) reached.add(f);
  while (queue.length) {
    const from = queue.pop() as string;
    for (const spec of importSpecifiers(Reader.parse(from, readFileSync(from, "utf8")))) {
      const target = resolveImport(srcRoot, from, spec, known);
      if (target && !reached.has(target)) {
        reached.add(target);
        queue.push(target);
      }
    }
  }
  /** A script file is gated by the pages that use it, not only by its folder's path. */
  const scriptGated = (rel: string) => folderGated(folderOf(rel)) || reached.has(join(appDir, rel));

  const problems: Problem[] = [];
  for (const rel of files) {
    const name = basename(rel);
    const dir = folderOf(rel);
    const isMdx = MDX_PAGE.test(name);
    const isPage = PAGE_FILE.test(name) || METADATA_FILE.test(name);
    const isHandler = HANDLER_FILE.test(name);
    if (!isMdx && !isPage && !isHandler && !SCRIPT_FILE.test(name)) continue;
    if (isPage && dir === "" && ROOT_EXEMPT.test(name)) continue; // a root wrapper or root metadata file
    const isScript = !isMdx && !isPage && !isHandler;
    if (!isScript && (WRAPPER_FILE.test(name) ? !wrapperGated(dir, name) : !gatedPath(dir))) continue;
    const full = join(appDir, rel);
    let why: string | null;
    if (isMdx) why = "an MDX page cannot check the person: import its content into a page.tsx that checks first";
    else if (isPage) why = pageProblem(name, readFileSync(full, "utf8"));
    else if (isHandler) why = handlerProblem(name, readFileSync(full, "utf8"));
    else {
      // Any other script: read only for server actions, and only when a signed-in page uses it.
      if (!scriptGated(rel)) continue;
      const source = readFileSync(full, "utf8");
      // A "use server" file: every exported function. Any other: an action written inside it.
      why = Reader.parse(name, source).hasDirective("use server") ? actionProblem(name, source) : inlineActionProblem(Reader.parse(name, source));
    }
    if (why) problems.push({ file: rel.split(sep).join("/"), why });
  }
  // A file outside app/ that a signed-in page reaches through imports: read for server actions the same way.
  for (const abs of reached) {
    const rel = relative(appDir, abs);
    if (!rel.startsWith("..")) continue;
    const source = readFileSync(abs, "utf8");
    const r = Reader.parse(basename(abs), source);
    const why = r.hasDirective("use server") ? actionProblem(basename(abs), source) : inlineActionProblem(r);
    if (why) problems.push({ file: relative(srcRoot, abs).split(sep).join("/"), why });
  }
  return problems.sort((a, b) => a.file.localeCompare(b.file));
}

const missingChecks = (appDir: string) => findProblems(appDir).map((p) => p.file);

const HOW_TO_FIX =
  'These files serve a signed-in path with no check first. Make "await requirePagePerson();" ' +
  '(imported from "@/lib/auth/current-person") the first line of the default export of each page, ' +
  "layout, template, default and metadata image or sitemap file (requireAdministratorPage() for " +
  "administrators only; and the first line of generateMetadata, generateImageMetadata and " +
  'generateSitemaps), outside any try, and "await requireCurrentPerson();" or requireAdministrator() ' +
  "the first line of every exported method of each route handler and of every exported function of " +
  'each "use server" file, and the line right after "use server" in an action written inside a page ' +
  "(inside a leading try only when " +
  "nothing follows the try and every catch returns a response or rethrows). A comment does not count. " +
  "A \"use client\" page cannot: make page.tsx a server component that checks and renders it. " +
  "An MDX page cannot: import it into a page.tsx that checks. Only the root layout, template, " +
  "default and metadata files (app/icon.* and the like) may skip, and they must show nothing " +
  "private: never put the check in one of those, " +
  "because they also wrap /sign-in and it would send /sign-in to itself; one that needs the person " +
  "moves into (app)/. A page meant to be public goes in PUBLIC_PATHS (settings.ts). A layout, template " +
  "or default is checked when any page under it is signed-in: one shared only by public pages needs no " +
  "check and must show nothing private; one over public and signed-in pages must check, so move the " +
  "public pages into a route group of their own. A server action (a \"use server\" file, or an action written in any other file) is checked when a " +
  "signed-in page uses its file: it sits in or below that page's folder, or the page imports it, directly or " +
  "through other files, under app/ or elsewhere in the source folder; only a file used by public pages alone may " +
  "skip. An action a signed-in page reaches is checked even when it sits in a public folder (a sign-out button " +
  "in (app)/ importing sign-in/actions): give it a file no signed-in page imports, or check the person in it.";

// This file sits at <site>/tests/unit/auth/, and app/ is under the source root.
const SITE_ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const SITE_APP = [join(SITE_ROOT, "src", "app"), join(SITE_ROOT, "app")].find((d) => existsSync(d));

describe("every file on a gated path checks the person (control C26)", () => {
  it("holds for this site's app folder", () => {
    expect(SITE_APP, "no src/app or app folder found beside tests/").toBeDefined();
    expect(
      findProblems(SITE_APP!).map((p) => `${p.file}: ${p.why}`),
      HOW_TO_FIX,
    ).toEqual([]);
  });
});

describe("the check itself", () => {
  const dir = mkdtempSync(join(tmpdir(), "page-checks-"));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  const put = (rel: string, source: string) => {
    mkdirSync(join(dir, dirname(rel)), { recursive: true });
    writeFileSync(join(dir, rel), source);
  };
  const fixturePublic = (path: string) =>
    ["/sign-in", "/api/auth", "/api/cron", "/api/health"].some((b) => path === b || path.startsWith(`${b}/`));
  const IMPORT_PAGE = 'import { requirePagePerson } from "@/lib/auth/current-person";\n';
  const IMPORT_HANDLER = 'import { requireAdministrator, requireCurrentPerson } from "@/lib/auth/current-person";\n';
  const checked = `${IMPORT_PAGE}export default async function Page() {
  await requirePagePerson();
  return null;
}`;
  const unchecked = "export default async function Page() { return <p>secret</p>; }";

  // Pass: public paths, the root wrappers, and files that check first in every form the check reads.
  const passes: Record<string, string> = {
    "layout.tsx": "export default function RootLayout({ children }) { return children; }",
    "template.tsx": '"use client";\nexport default function Template({ children }) { return <div className="fade">{children}</div>; }',
    "default.tsx": "export default function Default() { return null; }",
    "icon.tsx": "export default function Icon() { return null; }",
    "sign-in/page.tsx": unchecked,
    "api/health/route.ts": "export async function GET() { return Response.json({ ok: true }); }",
    "api/cron/credential-check/route.ts": "export async function GET() { return Response.json({}); }",
    "api/auth/[...all]/route.ts": "export const GET = () => null;",
    "(app)/layout.tsx": checked.replace("function Page", "function Layout"),
    "(app)/page.tsx": checked,
    "(app)/admin/page.tsx": checked.replace(/requirePagePerson/g, "requireAdministratorPage"),
    "(app)/api/things/route.ts": `${IMPORT_HANDLER}export async function GET() { await requireCurrentPerson(); return Response.json({}); }`,
    "(app)/adv-returnto/page.tsx": `${IMPORT_PAGE}// returns the page once the person is known
export default async function Page({ searchParams }: { searchParams: Promise<{ returnTo?: string }> }) {
  await requirePagePerson();
  return <p/>;
}`,
    "(app)/arrow-ok/page.tsx": `${IMPORT_PAGE}const Page = async () => {\n  const person = await requirePagePerson();\n  return <p>{person.displayName}</p>;\n};\nexport default Page;`,
    "(app)/named-default/page.tsx": `${IMPORT_PAGE}async function Page() { await requirePagePerson(); return <p/>; }\nexport { Page as default };`,
    "(app)/aliased/page.tsx": 'import { requirePagePerson as signedIn } from "@/lib/auth/current-person";\nexport default async function Page() { await signedIn(); return <p/>; }',
    "(app)/namespace/page.tsx": 'import * as auth from "../../lib/auth/current-person";\nexport default async function Page() { await auth.requirePagePerson(); return <p/>; }',
    "(app)/meta-ok/page.tsx": `${IMPORT_PAGE}export async function generateMetadata() { await requirePagePerson(); return { title: "x" }; }\nexport default async function Page() { await requirePagePerson(); return <p/>; }`,
    "(app)/api/both/route.ts": `${IMPORT_HANDLER}export async function GET() { try { const p = await requireCurrentPerson(); return Response.json(p); } catch { return new Response(null, { status: 401 }); } }
export const POST = async () => { await requireAdministrator(); return Response.json({}); };`,
    "(app)/api/rethrow/route.tsx": `${IMPORT_HANDLER}export async function GET() {
  try { await requireAdministrator(); return Response.json({}); }
  catch (e) { if (e instanceof Error) { return new Response(null, { status: 403 }); } else { throw e; } }
}`,
    "(app)/reports/[id]/opengraph-image.tsx": `${IMPORT_PAGE}export async function generateImageMetadata() { await requirePagePerson(); return []; }
export default async function Image() { await requirePagePerson(); return null; }`,
    // A route group's layout and template over public pages only: nothing gated to wrap.
    "(public)/layout.tsx": "export default function PublicLayout({ children }) { return children; }",
    "(public)/template.tsx": "export default function PublicTemplate({ children }) { return children; }",
    "(public)/sign-in/help/page.tsx": unchecked,
    "(mixed)/sign-in/faq/page.tsx": unchecked.replace("secret", "faq"), // public, beside the gated (mixed)/dash
    // Server actions that check first, in their own file and written inside a page.
    "(app)/admin/ok-actions.ts": `"use server";
${IMPORT_HANDLER}export async function renameThing() { await requireAdministrator(); return { ok: 1 }; }
export const archiveThing = async () => { try { await requireCurrentPerson(); return { ok: 1 }; } catch { return { ok: 0 }; } };`,
    "(app)/inline-ok/page.tsx": `${IMPORT_PAGE}import { requireAdministrator } from "@/lib/auth/current-person";
export default async function Page() {
  await requirePagePerson();
  async function save() { "use server"; await requireAdministrator(); }
  return <form action={save} />;
}`,
    // Public, or not an action file: not read.
    "sign-in/actions.ts": '"use server";\nexport async function hello() { return 1; }',
    "(app)/reports/format.ts": "export function format(n: number) { return String(n); }",
  };
  // Fail: each skips the check, checks too late, or hides it in a form that does not run first.
  const fails: Record<string, string> = {
    "(app)/reports/page.tsx": unchecked,
    "(app)/reports/[id]/layout.tsx": unchecked,
    "(app)/reports/[id]/template.tsx": unchecked,
    "(app)/@modal/page.tsx": unchecked,
    "(app)/@modal/default.tsx": unchecked,
    "(app)/late/page.tsx": `${IMPORT_PAGE}export default async function Page() { if (x) return null; await requirePagePerson(); return <p/>; }`,
    "(app)/meta/page.tsx": `export async function generateMetadata() { return { title: await secret() }; }\n${checked}`,
    "(app)/meta-twice/page.tsx": `${IMPORT_PAGE}export async function generateMetadata() { return { title: await secret() }; }
export default async function Page() { await requirePagePerson(); await requirePagePerson(); return <p/>; }`,
    "(app)/client/page.tsx": '"use client";\nexport default function Page() { return <p>hi</p>; }',
    "(app)/commented/page.tsx": `${IMPORT_PAGE}export default async function Page() {\n  // await requirePagePerson();\n  return <p>secret</p>;\n}`,
    "(app)/arrow/page.tsx": `${IMPORT_PAGE}async function who() { return await requirePagePerson(); }\nconst Page = async () => <p>secret</p>;\nexport default Page;`,
    "(app)/not-imported/page.tsx": "async function requirePagePerson() {}\nexport default async function Page() { await requirePagePerson(); return <p>secret</p>; }",
    "(app)/reexport/page.tsx": 'export { default } from "../somewhere-else";',
    "(app)/api/two/route.ts": `${IMPORT_HANDLER}export async function GET() { await requireCurrentPerson(); return Response.json({}); }
export async function POST() { return Response.json({ secret: 1 }); }`,
    "api/things/route.ts": "export async function GET() { return Response.json({ secret: 1 }); }",
    "sign-in-help/page.tsx": unchecked,
    // A catch that swallows redirect() lets the page render for a signed-out caller.
    "(app)/swallow/page.tsx": `${IMPORT_PAGE}export default async function Page() {
  try { await requirePagePerson(); } catch (e) { console.error(e); }
  return <p>secret</p>;
}`,
    // An empty catch, then code after the try: any member reads what only administrators may.
    "(app)/api/swallow/route.ts": `${IMPORT_HANDLER}export async function GET() {
  try { await requireAdministrator(); } catch {}
  return Response.json({ adminOnly: 1 });
}`,
    "(app)/api/after-try/route.ts": `${IMPORT_HANDLER}export async function GET() {
  try { await requireAdministrator(); } catch (e) { return new Response(null, { status: 403 }); }
  return Response.json({ adminOnly: 1 });
}`,
    "(app)/api/logs/route.ts": `${IMPORT_HANDLER}export async function GET() {
  try { await requireAdministrator(); return Response.json({}); } catch (e) { console.error(e); }
}`,
    "(app)/api/finally/route.ts": `${IMPORT_HANDLER}export async function GET() {
  try { await requireAdministrator(); return Response.json({}); } finally { return Response.json({ adminOnly: 1 }); }
}`,
    "(app)/api/jsx/route.tsx": "export async function GET() { return Response.json({ secret: 1 }); }",
    "(app)/reports/[id]/twitter-image.tsx": "export default async function Image() { return null; }",
    "(app)/reports/[id]/icon.tsx": `${IMPORT_PAGE}export async function generateImageMetadata() { return [{ id: await secret() }]; }
export default async function Icon() { await requirePagePerson(); return null; }`,
    "(app)/reports/sitemap.ts": "export default async function sitemap() { return []; }",
    "(app)/notes/page.mdx": "# Secret notes",
    "(app)/reports/template.tsx": '"use client";\nexport default function Template({ children }) { return children; }',
    // A group layout over a public page and a gated one wraps the gated one too.
    "(mixed)/layout.tsx": "export default function MixedLayout({ children }) { return children; }",
    "(mixed)/dash/page.tsx": unchecked,
    // Server actions: any signed-in member could run these.
    "(app)/admin/actions.ts": '"use server";\nexport async function deleteEveryone() { return { adminOnly: 1 }; }',
    "(app)/admin/half-actions.ts": `"use server";
${IMPORT_HANDLER}export async function renameThing() { await requireAdministrator(); return {}; }
async function wipe() { return { adminOnly: 1 }; }
export { wipe };`,
    "(app)/inline/page.tsx": `${IMPORT_PAGE}export default async function Page() {
  await requirePagePerson();
  async function wipe() { "use server"; return { adminOnly: 1 }; }
  return <form action={wipe} />;
}`,
  };
  for (const [rel, source] of Object.entries({ ...passes, ...fails })) put(rel, source);

  // The fixtures are graded by the template's own public paths, never this site's settings, so a site
  // that makes "/" public (or renames a server-to-server path) still runs this self-test green.
  const problems = findProblems(dir, fixturePublic);
  const missing = problems.map((p) => p.file);

  it("flags every gated file that does not check first", () => {
    expect(missing).toEqual(Object.keys(fails).sort((a, b) => a.localeCompare(b)));
  });

  it("passes the root wrappers, public paths and files that check first", () => {
    for (const ok of Object.keys(passes)) expect(missing).not.toContain(ok);
  });

  it("names the method a route file leaves unchecked", () => {
    expect(problems.find((p) => p.file === "(app)/api/two/route.ts")?.why).toMatch(/^POST /);
  });

  it("names the action a \"use server\" file leaves unchecked", () => {
    expect(problems.find((p) => p.file === "(app)/admin/half-actions.ts")?.why).toBe(
      "server action wipe does not start with await requireCurrentPerson()",
    );
  });

  // Other PUBLIC_PATHS: a group file's gating follows the pages under it, not the group's parent path.
  it("decides a group's layout, template and default by the pages it wraps", () => {
    const site = mkdtempSync(join(tmpdir(), "page-checks-groups-"));
    try {
      const at = (rel: string, source: string) => {
        mkdirSync(join(site, dirname(rel)), { recursive: true });
        writeFileSync(join(site, rel), source);
      };
      const wrapper = "export default function Wrapper({ children }) { return children; }";
      at("layout.tsx", wrapper);
      at("(marketing)/layout.tsx", wrapper); // wraps only /about and /: public, skipped
      at("(marketing)/about/page.tsx", unchecked);
      at("(marketing)/page.tsx", unchecked);
      at("(app)/template.tsx", wrapper); // "/" is public, but it wraps the gated /dash
      at("(app)/@modal/default.tsx", wrapper); // rendered by (app)'s layout around /dash
      at("(app)/dash/page.tsx", checked);
      const publicPaths = ["/", "/about"];
      const isPublic = (path: string) => publicPaths.includes(path) || fixturePublic(path);
      expect(findProblems(site, isPublic).map((p) => p.file)).toEqual(["(app)/@modal/default.tsx", "(app)/template.tsx"]);
    } finally {
      rmSync(site, { recursive: true, force: true });
    }
  });

  // "/" public: an action is served on the pages that use it, not on its folder's path.
  it('reads a "use server" file by the pages that use it, with "/" public', () => {
    const site = mkdtempSync(join(tmpdir(), "page-checks-actions-"));
    const app = join(site, "app"); // so "@/app/..." names a file here, as it does on a site
    try {
      const at = (rel: string, source: string) => {
        mkdirSync(join(app, dirname(rel)), { recursive: true });
        writeFileSync(join(app, rel), source);
      };
      const open = (fn: string) => `"use server";\nexport async function ${fn}() { return { adminOnly: 1 }; }`;
      at("page.tsx", unchecked.replace("secret", "welcome")); // the public landing page
      at("(app)/dash/page.tsx", checked);
      at("actions.ts", open("wipe")); // app/ root: serves "/", but (app)/dash uses it
      at("(app)/actions.ts", open("deleteEveryone")); // the group root, over the gated /dash
      at("(marketing)/about/page.tsx", unchecked.replace("secret", "about"));
      at("(marketing)/shared-actions.ts", open("exportAll")); // beside public pages, but used by a gated one
      at("(app)/dash/form.tsx", '"use client";\nimport { exportAll } from "@/app/(marketing)/shared-actions";\nexport function Form() { return <form action={exportAll} />; }');
      at("(marketing)/js-actions.ts", open("viaJs")); // imported by a gated file with a ".js" specifier
      at("(app)/dash/other.tsx", '"use client";\nimport { viaJs } from "../../(marketing)/js-actions.js";\nexport function Other() { return <form action={viaJs} />; }');
      // A shared component outside app/ chains a gated page to an action beside public pages, two hops away.
      mkdirSync(join(site, "components"), { recursive: true });
      writeFileSync(join(site, "components", "wrap.tsx"), 'import { Inner } from "./inner";\nexport function Wrap() { return <Inner />; }');
      writeFileSync(join(site, "components", "inner.tsx"), 'import { chained } from "@/app/(marketing)/chained-actions";\nexport function Inner() { return <form action={chained} />; }');
      at("(marketing)/chained-actions.ts", open("chained")); // public folder, reached from /dash via components/wrap -> inner
      at("(app)/dash/uses-wrap.tsx", 'import { Wrap } from "@/components/wrap";\nexport function Uses() { return <Wrap />; }');
      // An inline action in a helper file, not a page: read when a gated folder holds it.
      at("(app)/dash/delete-form.tsx", 'export function DeleteForm() {\n  async function wipe() { "use server"; return { adminOnly: 1 }; }\n  return <form action={wipe} />;\n}');
      // An action outside app/, reached by a gated page: read the same way. Object-method actions, and .mjs files, too.
      mkdirSync(join(site, "actions"), { recursive: true });
      writeFileSync(join(site, "actions", "admin.ts"), open("outside"));
      at("(app)/dash/uses-outside.tsx", 'import { outside } from "@/actions/admin";\nexport function UsesOutside() { return <form action={outside} />; }');
      at("(app)/dash/obj.tsx", 'export const actions = { async wipe() { "use server"; return { adminOnly: 1 }; } };');
      at("(app)/dash/mjs-actions.mjs", open("viaMjs"));
      at("(marketing)/contact/page.tsx", 'import { send } from "./actions";\nexport default function Page() { return <form action={send} />; }');
      at("(marketing)/contact/actions.ts", open("send")); // public page, public action: skipped
      at("sign-in/actions.ts", open("hello")); // the sign-in folder: skipped
      const isPublic = (path: string) => path === "/" || ["/about", "/contact"].includes(path) || fixturePublic(path);
      expect(findProblems(app, isPublic).map((p) => p.file)).toEqual(["(app)/actions.ts", "(app)/dash/delete-form.tsx", "(app)/dash/mjs-actions.mjs", "(app)/dash/obj.tsx", "(marketing)/chained-actions.ts", "(marketing)/js-actions.ts", "(marketing)/shared-actions.ts", "actions.ts", "actions/admin.ts"]);
    } finally {
      rmSync(site, { recursive: true, force: true });
    }
  });

  // The examples ship beside the templates (not on a site): each passes the check it teaches.
  const examples = join(SITE_ROOT, "examples");
  it.skipIf(!existsSync(examples))("passes the skill's own examples", () => {
    const ex = mkdtempSync(join(tmpdir(), "page-checks-examples-"));
    try {
      const copy = (from: string, to: string) => {
        mkdirSync(join(ex, dirname(to)), { recursive: true });
        writeFileSync(join(ex, to), readFileSync(join(examples, from)));
      };
      copy("protected-layout.tsx", "(app)/layout.tsx");
      copy("protected-page.tsx", "(app)/page.tsx");
      copy("route-handler.ts", "(app)/api/hello/route.ts");
      expect(missingChecks(ex)).toEqual([]);
    } finally {
      rmSync(ex, { recursive: true, force: true });
    }
  });
});
