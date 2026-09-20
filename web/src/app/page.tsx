import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";
import { Hero } from "@/components/sections/Hero";
import { DeveloperDay } from "@/components/sections/DeveloperDay";
import { BodyNotServer } from "@/components/sections/BodyNotServer";
import { ContextDemo } from "@/components/sections/ContextDemo";
import { ProductDemo } from "@/components/sections/ProductDemo";
import { NotPomodoro } from "@/components/sections/NotPomodoro";
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
        <DeveloperDay />
        <BodyNotServer />
        <ContextDemo />
        <ProductDemo />
        <NotPomodoro />
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
