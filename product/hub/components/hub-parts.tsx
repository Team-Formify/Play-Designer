import * as React from "react";
import {
  AlertTriangle,
  Ban,
  BookOpen,
  CircleCheck,
  ClipboardList,
  Hammer,
  KeyRound,
  LayoutGrid,
  Mail,
  Scale,
  ScrollText,
  SquarePlus,
  UserMinus,
  UserPlus,
  Users,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";
import type { Action } from "@/lib/tiers";

/* ------------------------------------------------------------------ mark */

/** Inline, so nothing on this page waits on a network. */
export function Mark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 32 32"
      role="img"
      aria-label="Playbook mark"
      className={className}
    >
      <rect
        x="1.25"
        y="1.25"
        width="29.5"
        height="29.5"
        rx="7"
        className="fill-primary"
      />
      <g
        className="stroke-primary-foreground"
        fill="none"
        strokeWidth="1.9"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M8 24 C 12 24, 12 15, 16 15 C 20 15, 20 8, 24 8" />
        <path d="M20.6 8.4 L24 8 L23.6 11.4" />
      </g>
      <circle cx="8" cy="24" r="2.4" className="fill-primary-foreground" />
    </svg>
  );
}

/* ----------------------------------------------------------------- badge */

const badgeTone = {
  ok: "border-emerald-600/35 bg-emerald-500/10 text-emerald-700 dark:border-emerald-400/30 dark:text-emerald-400",
  pending:
    "border-dashed border-amber-500/50 bg-amber-500/10 text-amber-700 dark:text-amber-400",
  danger:
    "border-destructive/40 bg-destructive/10 text-destructive dark:border-red-400/35 dark:bg-red-500/10 dark:text-red-400",
  plain: "border-border bg-muted text-muted-foreground",
} as const;

export function Badge({
  tone = "plain",
  icon: Icon,
  className,
  children,
}: {
  tone?: keyof typeof badgeTone;
  icon?: LucideIcon;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium leading-4 whitespace-nowrap",
        badgeTone[tone],
        className,
      )}
    >
      {Icon ? <Icon className="h-3 w-3 shrink-0" aria-hidden /> : null}
      {children}
    </span>
  );
}

/* --------------------------------------------------------- action icons */

const ACTION_ICON: Record<string, LucideIcon> = {
  "Create a league": SquarePlus,
  "Invite a league admin": Mail,
  "See every league": LayoutGrid,
  "Suspend a league": Ban,
  "Add a team": SquarePlus,
  "Invite a head coach": UserPlus,
  "Set the league rulebook": Scale,
  "Read the audit log": ScrollText,
  "Remove a child on request": UserMinus,
  "Invite an assistant": UserPlus,
  "Manage the roster": Users,
  "Rotate the boys' word": KeyRound,
  "Open the playbook": BookOpen,
};

/* ------------------------------------------------------------ action row */

export function ActionRow({ action }: { action: Action }) {
  const Icon = ACTION_ICON[action.label] ?? ClipboardList;
  const built = !action.needsSchema;

  return (
    <li
      data-action={action.label}
      data-built={built ? "yes" : "no"}
      className={cn(
        "rounded-md border p-3",
        action.needsSchema && "border-dashed bg-muted/40",
        action.destructive &&
          "border-destructive/35 bg-destructive/[0.04] dark:border-red-400/25 dark:bg-red-500/[0.06]",
      )}
    >
      <div className="flex gap-3">
        <span
          className={cn(
            "mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md border",
            action.destructive
              ? "border-destructive/30 text-destructive dark:border-red-400/30 dark:text-red-400"
              : built
                ? "border-border bg-background text-foreground"
                : "border-dashed text-muted-foreground",
          )}
        >
          <Icon className="h-4 w-4" aria-hidden />
        </span>

        <div className="min-w-0 flex-1">
          <p
            className={cn(
              "text-sm font-medium leading-snug",
              action.destructive && "text-destructive dark:text-red-400",
              !built && !action.destructive && "text-muted-foreground",
            )}
          >
            {action.label}
          </p>
          <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
            {action.detail}
          </p>

          <div className="mt-2 flex flex-wrap items-center gap-1.5">
            <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-[11px] break-all text-muted-foreground">
              {action.fn ?? "no function yet"}
            </code>
            {built ? (
              <Badge tone="ok" icon={CircleCheck}>
                In the schema
              </Badge>
            ) : (
              <Badge tone="pending" icon={Hammer}>
                Not built — needs schema
              </Badge>
            )}
            {action.destructive ? (
              <Badge tone="danger" icon={AlertTriangle}>
                Destructive
              </Badge>
            ) : null}
          </div>
        </div>
      </div>
    </li>
  );
}
