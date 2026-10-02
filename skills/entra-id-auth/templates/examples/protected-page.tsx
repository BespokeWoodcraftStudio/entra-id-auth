/**
 * Example: the first line of every signed-in page (control C26).
 *
 * Every page.tsx, layout.tsx, template.tsx and default.tsx on a gated path
 * (everything not in PUBLIC_PATHS, which is every page under src/app/(app)/)
 * starts with `await requirePagePerson()`, outside any try, before it reads
 * any data or returns any markup. redirect() works by throwing, so a catch
 * around the call would swallow it and render the page anyway. For a page only administrators may see, use
 * `await requireAdministratorPage()`. A page that exports generateMetadata
 * calls it there as well, because metadata renders on its own.
 *
 * Why the page and not only the layout: Next renders a layout and its page in
 * parallel. When the layout redirects, a page with no check of its own is
 * still rendered and sent in the body of the 307, where anyone who does not
 * follow the redirect (curl, a script) can read it.
 *
 * A "use client" page cannot call it. Make page.tsx a server component that
 * calls it and renders the client component. An MDX page cannot either:
 * import its content into a page.tsx that calls it.
 *
 * tests/unit/auth/page-checks.test.ts parses every gated page, layout,
 * template and default file and fails when its default export (or its
 * generateMetadata) does not start with the call. A comment does not count.
 */
import { requirePagePerson } from "@/lib/auth/current-person";

export default async function Page() {
  const person = await requirePagePerson();

  return (
    <main>
      <h1>Hello, {person.displayName}</h1>
    </main>
  );
}
