import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { Hero } from "@/components/sections/Hero";
import { ContextDemo } from "@/components/sections/ContextDemo";
import { ProductDemo } from "@/components/sections/ProductDemo";
import { NotPomodoro } from "@/components/sections/NotPomodoro";
import { Meetings } from "@/components/sections/Meetings";
import { Badges } from "@/components/sections/Badges";
import { Comparison } from "@/components/sections/Comparison";
import { BeforeAfter } from "@/components/sections/BeforeAfter";
import { Privacy } from "@/components/sections/Privacy";
import { OpenSource } from "@/components/sections/OpenSource";
import { FinalCta } from "@/components/sections/FinalCta";

export default function Home() {
  return (
    <>
      <Nav />
      <main id="main">
        {/* Order is an argument: recognise yourself, see the comparison, then
            see what the app actually does about it, then why you can trust it. */}
        <Hero />
        <ContextDemo />
        <ProductDemo />
        <NotPomodoro />
        {/* NotPomodoro ends on "a timer doesn't know you're on a call", so the
            section that says what this one actually does about a call follows it
            directly, and lands before the Comparison row that claims it. */}
        <Meetings />
        {/* Badges answer the same objection NotPomodoro just answered, one
            register down: that one says this is not a timer, this one says it is
            not a streak either. It also has to land before Comparison, which
            claims the shelf in a row of its own. */}
        <Badges />
        <Comparison />
        <BeforeAfter />
        <Privacy />
        <OpenSource />
        <FinalCta />
      </main>
      <Footer />
    </>
  );
}
