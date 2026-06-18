/** @jsxImportSource @opentui/solid */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { TuiPlugin, TuiPluginModule } from "@opencode-ai/plugin/tui";
import { SidebarPanel } from "./better-prompt/tui/sidebar-panel";
import { AuditRoute, ConfigRoute, ToggleRoute } from "./better-prompt/tui/routes";

// :::: TUI Plugin :::: //////////////////////////////////////

const tui: TuiPlugin = async (api) => {
  function getAuditPath(): string {
    return join(api.state.path.directory, ".opencode", "better-prompt", "audit.json");
  }

  // Track previous route so we can navigate back
  let prevRoute: { name: string; params?: Record<string, unknown> } = {
    name: "home",
  };

  function goBack() {
    api.route.navigate(prevRoute.name, prevRoute.params);
  }

  function snapshotCurrentRoute() {
    return {
      name: api.route.current.name,
      params: (api.route.current as Record<string, unknown>).params as
        | Record<string, unknown>
        | undefined,
    };
  }

  // :::: Command handlers (orchestration) :::: /////////////

  function handleToggle() {
    prevRoute = snapshotCurrentRoute();
    api.route.navigate("better-prompt:toggle");
  }

  function handleConfig() {
    prevRoute = snapshotCurrentRoute();
    api.route.navigate("better-prompt:config");
  }

  function handleAudit() {
    const auditPath = getAuditPath();

    if (!existsSync(auditPath)) {
      api.ui.toast({
        variant: "info",
        message: "No audit data available. Enable with /better-prompt:toggle audit on",
      });
      return;
    }

    const allLines = readFileSync(auditPath, "utf8")
      .trim()
      .split("\n")
      .filter((l: string) => l.trim());

    if (allLines.length === 0) {
      api.ui.toast({ variant: "info", message: "Audit trail is empty." });
      return;
    }

    prevRoute = snapshotCurrentRoute();
    api.route.navigate("better-prompt:audit");
  }

  // :::: Registration :::: /////////////////////////////////

  api.slots.register({
    order: 150,
    slots: {
      sidebar_content(ctx) {
        return (
          <SidebarPanel
            theme={(ctx.theme as unknown as { current: Record<string, unknown> }).current ?? {}}
          />
        );
      },
    },
  });

  api.route.register([
    { name: "better-prompt:toggle", render: () => <ToggleRoute api={api} goBack={goBack} /> },
    { name: "better-prompt:config", render: () => <ConfigRoute api={api} goBack={goBack} /> },
    { name: "better-prompt:audit", render: () => <AuditRoute api={api} goBack={goBack} /> },
  ]);

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
  });
};

// :::: Module export :::: ///////////////////////////////////

const plugin: TuiPluginModule & { id: string } = {
  id: "@objctp/opencode-better-prompt",
  tui,
};

export default plugin;
