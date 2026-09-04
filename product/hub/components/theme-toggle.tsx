"use client";

import * as React from "react";
import { Moon, Sun } from "lucide-react";

import { Button } from "@/components/ui/button";

/**
 * The only control on this page that actually does something, so it is the only
 * one drawn as a Button. Theme is applied in an effect rather than in a
 * pre-hydration script: writing `class="dark"` onto <html> from the server
 * would hand React a hydration mismatch, and a console error is a bug here.
 */
export function ThemeToggle() {
  const [dark, setDark] = React.useState<boolean | null>(null);

  React.useEffect(() => {
    const saved = window.localStorage.getItem("hub-theme");
    setDark(
      saved
        ? saved === "dark"
        : window.matchMedia("(prefers-color-scheme: dark)").matches,
    );
  }, []);

  React.useEffect(() => {
    if (dark === null) return;
    document.documentElement.classList.toggle("dark", dark);
    window.localStorage.setItem("hub-theme", dark ? "dark" : "light");
  }, [dark]);

  return (
    <Button
      variant="outline"
      size="icon"
      data-testid="theme-toggle"
      aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
      aria-pressed={dark === true}
      onClick={() => setDark((v) => !v)}
    >
      {dark ? (
        <Sun className="h-4 w-4" aria-hidden />
      ) : (
        <Moon className="h-4 w-4" aria-hidden />
      )}
    </Button>
  );
}
