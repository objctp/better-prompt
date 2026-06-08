/** @jsxImportSource @opentui/solid */
import type { TuiPlugin, TuiPluginModule } from "@opencode-ai/plugin/tui"
import { useKeyboard } from "@opentui/solid"
import { createSignal } from "solid-js"
import {
  existsSync,
  readFileSync,
  writeFileSync,
} from "node:fs"
import { join } from "node:path"

// ── Types ──────────────────────────────────────────────────

interface Config {
  enabled: boolean
  correction: boolean
  correction_model: string
  translation: boolean
  translation_model: string
  enhancement: boolean
  enhancement_model: string
  audit: boolean
  verbose: boolean
}

const CONFIG_DEFAULTS: Config = {
  enabled: true,
  correction: true,
  correction_model: "haiku",
  translation: false,
  translation_model: "haiku",
  enhancement: false,
  enhancement_model: "sonnet",
  audit: true,
  verbose: false,
}

const TOGGLEABLE = [
  "enabled",
  "correction",
  "translation",
  "enhancement",
  "audit",
  "verbose",
] as const

// ── Config parsing (duplicated from server plugin) ─────────

function parseConfig(configPath: string): Config {
  if (!existsSync(configPath)) return { ...CONFIG_DEFAULTS }

  const raw = readFileSync(configPath, "utf8")
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---/)
  if (!fmMatch) return { ...CONFIG_DEFAULTS }

  const fm = fmMatch[1]
  const get = (key: string): string | undefined => {
    const m = fm.match(new RegExp(`^${key}:\\s*(.+)$`, "m"))
    return m ? m[1].trim() : undefined
  }

  const bool = (key: string, fallback: boolean): boolean => {
    const v = get(key)
    return v !== undefined ? v === "true" : fallback
  }

  const str = (key: string, fallback: string): string => {
    const v = get(key)
    return v !== undefined ? v : fallback
  }

  return {
    enabled: bool("enabled", CONFIG_DEFAULTS.enabled),
    correction: bool("correction", CONFIG_DEFAULTS.correction),
    correction_model: str("correction_model", CONFIG_DEFAULTS.correction_model),
    translation: bool("translation", CONFIG_DEFAULTS.translation),
    translation_model: str("translation_model", CONFIG_DEFAULTS.translation_model),
    enhancement: bool("enhancement", CONFIG_DEFAULTS.enhancement),
    enhancement_model: str("enhancement_model", CONFIG_DEFAULTS.enhancement_model),
    audit: bool("audit", CONFIG_DEFAULTS.audit),
    verbose: bool("verbose", CONFIG_DEFAULTS.verbose),
  }
}

function updateConfig(configPath: string, updates: Partial<Config>): void {
  let raw = ""
  if (existsSync(configPath)) {
    raw = readFileSync(configPath, "utf8")
  }

  let fm = ""
  let body = ""
  const fmMatch = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/)
  if (fmMatch) {
    fm = fmMatch[1]
    body = fmMatch[2]
  }

  for (const [key, value] of Object.entries(updates)) {
    if (value === undefined) continue
    const line = `${key}: ${value}`
    const regex = new RegExp(`^${key}: .+$`, "m")
    if (regex.test(fm)) {
      fm = fm.replace(regex, line)
    } else {
      fm += `\n${line}`
    }
  }

  writeFileSync(configPath, `---\n${fm}\n---\n${body}`)
}

// ── Types ──────────────────────────────────────────────────

interface SelectOption {
  title: string
  description: string
  value: string
}

// ── Reusable SelectView component ──────────────────────────
// Renders at route level (not inside dialog) so useKeyboard
// receives all key events including Enter and Escape.

function SelectView(props: {
  title: string
  options: () => SelectOption[]
  onSelect: (opt: SelectOption) => void
  onBack: () => void
}) {
  const [idx, setIdx] = createSignal(0)

  useKeyboard((key: any) => {
    const opts = props.options()
    const max = opts.length - 1
    if (key.name === "up" || key.name === "k") {
      setIdx((i: number) => Math.max(0, i - 1))
    }
    if (key.name === "down" || key.name === "j") {
      setIdx((i: number) => Math.min(max, i + 1))
    }
    if (key.name === "return") {
      const opt = opts[idx()]
      if (opt) props.onSelect(opt)
    }
    if (key.name === "escape") {
      props.onBack()
    }
  })

  return (
    <box border padding={{ top: 0, bottom: 0, left: 1, right: 1 }}>
      <text bold>{props.title}</text>
      {props.options().map((opt: SelectOption, i: number) => (
        <text fg={idx() === i ? "#ffffff" : "#888888"}>
          {(idx() === i ? "> " : "  ") + opt.title + "  " + opt.description}
        </text>
      ))}
      <text fg="#555555">  Up/Dn Navigate   Enter Select   Esc Back</text>
    </box>
  )
}

// ── TUI Plugin ─────────────────────────────────────────────

const tui: TuiPlugin = async (api) => {
  const CONFIG_PATH = join(
    process.env.HOME || "~",
    ".config",
    "opencode",
    "better-prompt.local.md",
  )

  function getAuditPath(): string {
    return join(
      api.state.path.directory,
      ".opencode",
      "better-prompt",
      "audit.json",
    )
  }

  // Track previous route so we can navigate back
  let prevRoute: { name: string; params?: Record<string, unknown> } = { name: "home" }

  function goBack() {
    api.route.navigate(prevRoute.name, prevRoute.params)
  }

  // ── /better-prompt:toggle ────────────────────────────────

  function handleToggle() {
    prevRoute = { name: api.route.current.name, params: (api.route.current as any).params }
    api.route.navigate("better-prompt:toggle")
  }

  function ToggleRoute() {
    const [stages, setStages] = createSignal(
      TOGGLEABLE.map((stage) => {
        const config = parseConfig(CONFIG_PATH)
        return {
          title: stage,
          description: `Currently: ${(config as any)[stage] ? "ON" : "OFF"}`,
          value: stage,
        }
      }),
    )

    return (
      <SelectView
        title="Better Prompt: Toggle Stage"
        options={() => stages()}
        onSelect={(opt) => {
          const current = parseConfig(CONFIG_PATH)
          const newVal = !(current as any)[opt.value]
          updateConfig(CONFIG_PATH, { [opt.value]: newVal })
          api.ui.toast({
            variant: "success",
            message: `${opt.value} is now ${newVal ? "ON" : "OFF"}`,
          })
          // Update displayed state — stay open for more toggles
          setStages(
            TOGGLEABLE.map((stage) => {
              const cfg = parseConfig(CONFIG_PATH)
              return {
                title: stage,
                description: `Currently: ${(cfg as any)[stage] ? "ON" : "OFF"}`,
                value: stage,
              }
            }),
          )
        }}
        onBack={goBack}
      />
    )
  }

  // ── /better-prompt:config ────────────────────────────────

  function handleConfig() {
    prevRoute = { name: api.route.current.name, params: (api.route.current as any).params }
    api.route.navigate("better-prompt:config")
  }

  function ConfigRoute() {
    const config = parseConfig(CONFIG_PATH)
    const options = () => Object.entries(config).map(([k, v]) => {
      const isBool = typeof v === "boolean"
      return {
        title: k,
        description: `${v}${isBool ? "  (select to toggle)" : ""}`,
        value: k,
      }
    })

    return (
      <SelectView
        title="Better Prompt Configuration"
        options={options}
        onSelect={(opt) => {
          const key = opt.value as keyof Config
          const currentVal = config[key]

          if (typeof currentVal === "boolean") {
            updateConfig(CONFIG_PATH, { [key]: !currentVal })
            api.ui.toast({
              variant: "success",
              message: `${key}: ${currentVal} -> ${!currentVal}`,
            })
          } else {
            api.ui.toast({
              variant: "info",
              message: `${key} = ${currentVal}  (edit ${CONFIG_PATH} to change)`,
              duration: 5000,
            })
          }
          goBack()
        }}
        onBack={goBack}
      />
    )
  }

  // ── /better-prompt:audit ─────────────────────────────────

  function handleAudit() {
    const auditPath = getAuditPath()

    if (!existsSync(auditPath)) {
      api.ui.toast({
        variant: "info",
        message:
          "No audit data available. Enable with /better-prompt:toggle audit on",
      })
      return
    }

    const allLines = readFileSync(auditPath, "utf8")
      .trim()
      .split("\n")
      .filter((l) => l.trim())

    if (allLines.length === 0) {
      api.ui.toast({ variant: "info", message: "Audit trail is empty." })
      return
    }

    prevRoute = { name: api.route.current.name, params: (api.route.current as any).params }
    api.route.navigate("better-prompt:audit")
  }

  function AuditRoute() {
    const auditPath = getAuditPath()

    if (!existsSync(auditPath)) {
      return (
        <box border padding={{ top: 0, bottom: 0, left: 1, right: 1 }}>
          <text>No audit data available.</text>
        </box>
      )
    }

    const allLines = readFileSync(auditPath, "utf8")
      .trim()
      .split("\n")
      .filter((l) => l.trim())

    if (allLines.length === 0) {
      return (
        <box border padding={{ top: 0, bottom: 0, left: 1, right: 1 }}>
          <text>Audit trail is empty.</text>
        </box>
      )
    }

    const recent = allLines.slice(-10)
    const auditOptions: SelectOption[] = []

    for (let i = 0; i < recent.length; i++) {
      try {
        const entry = JSON.parse(recent[i])
        const num = allLines.length - recent.length + i + 1
        const mistakes = entry.mistakes?.length ?? 0
        const parts: string[] = [entry.prompt.substring(0, 60)]
        if (entry.language) parts.push(`lang: ${entry.language}`)
        if (mistakes > 0) parts.push(`${mistakes} mistake${mistakes > 1 ? "s" : ""}`)
        auditOptions.push({
          title: `Entry #${num}`,
          description: parts.join(" | "),
          value: String(num),
        })
      } catch {
        // skip malformed entries
      }
    }

    auditOptions.push({
      title: "Clear audit trail",
      description: `${allLines.length} entries total`,
      value: "clear",
    })

    return (
      <SelectView
        title="Audit Trail"
        options={() => auditOptions}
        onSelect={(opt) => {
          if (opt.value === "clear") {
            writeFileSync(auditPath, "")
            api.ui.toast({
              variant: "success",
              message: "Audit trail cleared.",
            })
            goBack()
            return
          }
          const num = parseInt(opt.value, 10)
          const line = allLines[num - 1]
          try {
            const entry = JSON.parse(line)
            const details: string[] = [
              `#${num} ${entry.date}`,
              `Original: "${entry.prompt}"`,
            ]
            if (entry.language) details.push(`Language: ${entry.language}`)
            if (entry.corrected)
              details.push(`Corrected: "${entry.corrected}"`)
            if (entry.enhanced)
              details.push(`Enhanced: "${entry.enhanced}"`)
            if (entry.mistakes?.length > 0) {
              details.push(
                "Mistakes: " +
                  entry.mistakes
                    .map(
                      (m: any) =>
                        `[${m.type}] "${m.original}" -> "${m.correction}"`,
                    )
                    .join("; "),
              )
            }
            if (entry.models) {
              const used: string[] = []
              if (entry.models.correction)
                used.push(`correction=${entry.models.correction}`)
              if (entry.models.translation)
                used.push(`translation=${entry.models.translation}`)
              if (entry.models.enhancement)
                used.push(`enhancement=${entry.models.enhancement}`)
              if (used.length) details.push(`Models: ${used.join(", ")}`)
            }
            api.ui.toast({
              variant: "info",
              message: details.join("\n"),
              duration: 8000,
            })
          } catch {
            // skip
          }
          goBack()
        }}
        onBack={goBack}
      />
    )
  }

  // ── Route + Command registration ─────────────────────────

  api.route.register([
    { name: "better-prompt:toggle", render: () => <ToggleRoute /> },
    { name: "better-prompt:config", render: () => <ConfigRoute /> },
    { name: "better-prompt:audit", render: () => <AuditRoute /> },
  ])

  api.keymap.registerLayer({
    commands: [
      {
        name: "better-prompt.toggle",
        title: "BP: Toggle Stage",
        category: "Better Prompt",
        namespace: "palette",
        slashName: "better-prompt:toggle",
        run: handleToggle,
      },
      {
        name: "better-prompt.config",
        title: "BP: Show Config",
        category: "Better Prompt",
        namespace: "palette",
        slashName: "better-prompt:config",
        run: handleConfig,
      },
      {
        name: "better-prompt.audit",
        title: "BP: Audit Trail",
        category: "Better Prompt",
        namespace: "palette",
        slashName: "better-prompt:audit",
        run: handleAudit,
      },
    ],
  })
}

// ── Module export ──────────────────────────────────────────

const plugin: TuiPluginModule & { id: string } = {
  id: "@objctp/opencode-better-prompt",
  tui,
}

export default plugin
