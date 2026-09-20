import { meetings as copy } from "@/content/copy";
import { Section, Kicker, Headline, Lede } from "../ui/Primitives";

/**
 * Short on purpose.
 *
 * An earlier version of this section explained the whole mechanism: four signal
 * states, a worked timeline of a real call, every ceiling, and three named edge
 * cases. All of it was true and none of it belonged on a landing page. Somebody
 * deciding whether a break app will embarrass them in a standup needs one
 * answer, not an architecture review. The detail still exists, in
 * docs/BREAK-DECISION.md, where the people who want it will look.
 */
export function Meetings() {
  return (
    <Section id="meetings">
      <Kicker>{copy.kicker}</Kicker>
      <Headline>{copy.headline}</Headline>
      <Lede>{copy.sub}</Lede>

      <div className="mt-10 grid gap-x-10 gap-y-8 sm:grid-cols-3">
        {copy.facts.map((fact) => (
          <div key={fact.title}>
            <h3 className="font-mono text-sm font-medium text-fg">{fact.title}</h3>
            <p className="mt-2 text-sm leading-relaxed text-fg-muted">{fact.body}</p>
          </div>
        ))}
      </div>

      <div className="mt-10 border-l-2 border-line pl-5">
        <h3 className="font-mono text-sm font-medium text-fg">{copy.limit.title}</h3>
        <p className="mt-2 max-w-2xl text-sm leading-relaxed text-fg-muted">{copy.limit.body}</p>
      </div>
    </Section>
  );
}
