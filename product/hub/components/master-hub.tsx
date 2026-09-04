import {
  ArrowDown,
  ArrowRight,
  ClipboardList,
  Globe2,
  Hammer,
  Info,
  Landmark,
  Lock,
  Megaphone,
  ShieldCheck,
  type LucideIcon,
} from "lucide-react";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { BorderBeam } from "@/components/ui/border-beam";
import { ActionRow, Badge, Mark } from "@/components/hub-parts";
import { ThemeToggle } from "@/components/theme-toggle";
import { TIERS, type Tier } from "@/lib/tiers";
import { cn } from "@/lib/utils";

/* --------------------------------------------------------------- the model */

const TIER_META: Record<
  Tier,
  { step: string; icon: LucideIcon; scope: string; boundary: string; grants: string }
> = {
  platform: {
    step: "01",
    icon: Globe2,
    scope: "Every league",
    boundary: "The only tier that sees across tenants — and it sees names, team counts and seats. Never a team's plays.",
    grants: "grants one league one admin seat",
  },
  league: {
    step: "02",
    icon: Landmark,
    scope: "One league",
    boundary: "One league, and no way to reach another. The database refuses it, not the screen.",
    grants: "grants one team one head coach",
  },
  team: {
    step: "03",
    icon: ClipboardList,
    scope: "One team",
    boundary: "One team. An assistant cannot staff the team he is on.",
    grants: "grants the boys one read-only word",
  },
};

const ORDER: Tier[] = ["platform", "league", "team"];

const ALL = ORDER.flatMap((t) => TIERS[t].actions);
const TOTAL = ALL.length;
const PENDING = ALL.filter((a) => a.needsSchema).length;

/* ------------------------------------------------------------- components */

function Cascade({ label, down }: { label: string; down?: boolean }) {
  return (
    <div
      aria-hidden
      className={cn(
        "flex items-center justify-center gap-2 py-1 text-muted-foreground",
        !down && "lg:w-28 lg:flex-col lg:justify-start lg:py-0 lg:pt-28",
      )}
    >
      <ArrowDown className={cn("h-4 w-4 shrink-0", !down && "lg:hidden")} />
      {down ? null : (
        <ArrowRight className="hidden h-4 w-4 shrink-0 lg:block" />
      )}
      <span className="text-center text-[11px] font-medium uppercase leading-tight tracking-wide">
        {label}
      </span>
    </div>
  );
}

function BuildStatus({ className }: { className?: string }) {
  return (
    <div className={cn("rounded-xl border bg-muted/40 p-4 sm:p-5", className)}>
      <p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        What is actually built
      </p>
      <p className="mt-2 text-sm leading-relaxed">
        <span className="font-semibold tabular-nums">
          {TOTAL - PENDING} of {TOTAL}
        </span>{" "}
        capabilities are backed by a database function that already exists. The
        other {PENDING} are drawn, named and marked unbuilt.
      </p>
      <ul className="mt-4 space-y-3">
        {ORDER.map((t) => {
          const acts = TIERS[t].actions;
          const built = acts.filter((a) => !a.needsSchema).length;
          const Icon = TIER_META[t].icon;
          return (
            <li key={t}>
              <div className="flex items-center justify-between gap-2 text-xs">
                <span className="flex min-w-0 items-center gap-1.5 font-medium">
                  <Icon className="h-3.5 w-3.5 shrink-0" aria-hidden />
                  <span className="truncate">{TIERS[t].name}</span>
                </span>
                <span className="shrink-0 font-mono tabular-nums text-muted-foreground">
                  {built}/{acts.length}
                </span>
              </div>
              <div className="mt-1.5 flex gap-1" aria-hidden>
                {acts.map((a, i) => (
                  <span
                    key={i}
                    className={cn(
                      "h-2 flex-1 rounded-full",
                      a.needsSchema
                        ? "border border-dashed border-amber-500/60 bg-amber-500/15"
                        : "bg-emerald-500/70",
                    )}
                  />
                ))}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

function TierCard({ tier }: { tier: Tier }) {
  const t = TIERS[tier];
  const meta = TIER_META[tier];
  const Icon = meta.icon;
  const pending = t.actions.filter((a) => a.needsSchema).length;

  return (
    <Card
      data-tier={tier}
      className={cn(
        "flex h-full flex-col",
        tier === "platform" && "ring-1 ring-primary/15",
      )}
    >
      <CardHeader className="gap-0 space-y-3 p-4 sm:p-6">
        <div className="flex items-start gap-3">
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg border bg-muted text-foreground">
            <Icon className="h-5 w-5" aria-hidden />
          </span>
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <span className="font-mono text-xs text-muted-foreground">
                {meta.step}
              </span>
              <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                {meta.scope}
              </span>
            </div>
            <CardTitle className="mt-1 text-xl sm:text-2xl">{t.name}</CardTitle>
            <p className="mt-1 text-xs text-muted-foreground">
              Held by <span className="text-foreground">{t.who}</span>
            </p>
          </div>
        </div>

        <CardDescription className="text-sm leading-relaxed">
          {t.blurb}
        </CardDescription>

        <div className="flex flex-wrap items-center gap-1.5">
          <Badge tone="plain">
            {t.actions.length} {t.actions.length === 1 ? "action" : "actions"}
          </Badge>
          {pending > 0 ? (
            <Badge tone="pending" icon={Hammer}>
              {pending} not built
            </Badge>
          ) : (
            <Badge tone="ok" icon={ShieldCheck}>
              all in the schema
            </Badge>
          )}
        </div>
      </CardHeader>

      <CardContent className="flex flex-1 flex-col gap-3 p-4 pt-0 sm:p-6 sm:pt-0">
        <ul className="flex flex-col gap-2">
          {t.actions.map((a) => (
            <ActionRow key={a.label} action={a} />
          ))}
        </ul>

        <p className="mt-auto flex gap-2 rounded-md border border-dashed p-3 text-xs leading-relaxed text-muted-foreground">
          <Lock className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
          <span>{meta.boundary}</span>
        </p>
      </CardContent>
    </Card>
  );
}

/* -------------------------------------------------------------- the page */

export function MasterHub() {
  return (
    <div className="min-h-screen overflow-x-hidden bg-background text-foreground">
      <header className="sticky top-0 z-20 border-b bg-background/85 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center gap-3 px-4 py-3 sm:px-6">
          <Mark className="h-8 w-8 shrink-0 rounded-lg" />
          <div className="min-w-0 flex-1">
            <p className="text-sm font-semibold leading-tight tracking-tight">
              Playbook
            </p>
            <p className="truncate text-[11px] leading-tight text-muted-foreground">
              Master hub
            </p>
          </div>
          <ThemeToggle />
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-4 pb-16 pt-6 sm:px-6 sm:pt-10">
        {/* ------------------------------------------------------- hero */}
        <Card
          data-testid="hero"
          className="relative overflow-hidden p-0 shadow-none"
        >
          <BorderBeam
            size={220}
            duration={7}
            borderWidth={2}
            colorFrom="#ffaa40"
            colorTo="#9c40ff"
          />
          <BorderBeam
            size={220}
            duration={7}
            delay={3.5}
            borderWidth={2}
            colorFrom="#40c4ff"
            colorTo="#9c40ff"
          />

          <div className="p-5 sm:p-10 lg:grid lg:grid-cols-[1.5fr_minmax(250px,1fr)] lg:items-start lg:gap-10">
           <div>
            <div className="flex flex-wrap items-center gap-2">
              <Badge tone="plain" icon={Globe2}>
                Platform
              </Badge>
              <ArrowRight
                className="h-3.5 w-3.5 text-muted-foreground"
                aria-hidden
              />
              <Badge tone="plain" icon={Landmark}>
                League
              </Badge>
              <ArrowRight
                className="h-3.5 w-3.5 text-muted-foreground"
                aria-hidden
              />
              <Badge tone="plain" icon={ClipboardList}>
                Team
              </Badge>
            </div>

            <div className="mt-5 flex items-center gap-3">
              <Mark className="h-10 w-10 shrink-0 rounded-xl sm:h-12 sm:w-12" />
              <h1 className="text-3xl font-semibold tracking-tight sm:text-5xl">
                Playbook
              </h1>
            </div>

            <p className="mt-4 max-w-2xl text-base leading-relaxed text-muted-foreground sm:text-xl">
              One play engine, sold to a league and layered down to every team
              inside it — the hub opens the league, the league opens the team,
              the coach opens the book.
            </p>

            <dl className="mt-7 grid grid-cols-3 gap-2 sm:max-w-lg sm:gap-4">
              {[
                { k: "Tiers", v: ORDER.length },
                { k: "Capabilities", v: TOTAL },
                { k: "Awaiting schema", v: PENDING },
              ].map((s) => (
                <div key={s.k} className="rounded-lg border bg-muted/40 p-3">
                  <dd className="text-2xl font-semibold tabular-nums sm:text-3xl">
                    {s.v}
                  </dd>
                  <dt className="mt-0.5 text-[11px] uppercase leading-tight tracking-wide text-muted-foreground">
                    {s.k}
                  </dt>
                </div>
              ))}
            </dl>

            <p className="mt-6 flex max-w-2xl gap-2 text-xs leading-relaxed text-muted-foreground">
              <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
              <span>
                This screen is the face, not the capability. Nothing here calls
                an API — every tier below is read from{" "}
                <code className="rounded bg-muted px-1 py-0.5 font-mono text-[11px]">
                  lib/tiers.ts
                </code>
                , and each action names the database function that enforces it.
                Where there is no function yet, it says so instead of drawing a
                button.
              </span>
            </p>
           </div>

            <BuildStatus className="mt-8 lg:mt-1" />
          </div>
        </Card>

        {/* ---------------------------------------------------- cascade */}
        <section className="mt-10 sm:mt-14" aria-labelledby="cascade-heading">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2
                id="cascade-heading"
                className="text-xl font-semibold tracking-tight sm:text-2xl"
              >
                How permission cascades
              </h2>
              <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
                Each tier can only hand down what it holds, and never more. Read
                it left to right.
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-1.5">
              <Badge tone="ok" icon={ShieldCheck}>
                In the schema
              </Badge>
              <Badge tone="pending" icon={Hammer}>
                Not built
              </Badge>
            </div>
          </div>

          <div className="mt-5 grid gap-1 lg:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto_minmax(0,1fr)] lg:items-stretch lg:gap-2">
            <TierCard tier="platform" />
            <Cascade label={TIER_META.platform.grants} />
            <TierCard tier="league" />
            <Cascade label={TIER_META.league.grants} />
            <TierCard tier="team" />
          </div>

          {/* the end of the cascade: not a tier, no account */}
          <div className="grid gap-1 lg:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto_minmax(0,1fr)] lg:gap-2">
            <div className="hidden lg:block" />
            <div className="hidden lg:block lg:w-28" />
            <div className="hidden lg:block" />
            <div className="hidden lg:block lg:w-28" />
            <div className="flex flex-col">
              <Cascade label={TIER_META.team.grants} down />
              <div className="flex items-start gap-3 rounded-lg border border-dashed bg-muted/30 p-4">
                <Megaphone
                  className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground"
                  aria-hidden
                />
                <div className="min-w-0">
                  <p className="text-sm font-medium">The boys</p>
                  <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                    One word, read-only, one team, no account. The end of the
                    cascade holds nothing it can pass on.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <footer className="mt-12 border-t pt-6">
          <p className="text-xs leading-relaxed text-muted-foreground">
            {PENDING} of {TOTAL} capabilities are marked{" "}
            <span className="text-amber-700 dark:text-amber-400">
              not built
            </span>{" "}
            because no database function backs them yet — including the
            cross-tenant read a master hub needs, which is exactly what row
            level security is built to refuse and so has to be added
            deliberately and audited.
          </p>
        </footer>
      </main>
    </div>
  );
}

export default MasterHub;
