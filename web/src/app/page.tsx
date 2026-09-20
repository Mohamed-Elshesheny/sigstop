import { Nav } from "@/components/Nav";
import { Hero } from "@/components/sections/Hero";
import { ContextDemo } from "@/components/sections/ContextDemo";

export default function Home() {
  return (
    <>
      <Nav />
      <main id="main">
        <Hero />
        <ContextDemo />
      </main>
    </>
  );
}
