/** @jsxImportSource @opentui/solid */

import { useKeyboard } from "@opentui/solid";
import { createSignal } from "solid-js";

export interface SelectOption {
  title: string;
  description: string;
  value: string;
}

export function SelectView(props: {
  title: string;
  options: () => SelectOption[];
  onSelect: (opt: SelectOption) => void;
  onAltSelect?: (opt: SelectOption) => void;
  onBack: () => void;
}) {
  const [idx, setIdx] = createSignal(0);

  useKeyboard((key: { name: string }) => {
    const opts = props.options();
    const max = opts.length - 1;
    if (key.name === "up" || key.name === "k") {
      setIdx((i: number) => Math.max(0, i - 1));
    }
    if (key.name === "down" || key.name === "j") {
      setIdx((i: number) => Math.min(max, i + 1));
    }
    if (key.name === "return") {
      const opt = opts[idx()];
      if (opt) props.onSelect(opt);
    }
    if (key.name === "space") {
      if (props.onAltSelect) {
        const opt = opts[idx()];
        if (opt) props.onAltSelect(opt);
      }
    }
    if (key.name === "escape") {
      props.onBack();
    }
  });

  return (
    <box border paddingTop={0} paddingBottom={0} paddingLeft={1} paddingRight={1}>
      <text>
        <strong>{props.title}</strong>
      </text>
      {props.options().map((opt: SelectOption, i: number) => (
        <text fg={idx() === i ? "#ffffff" : "#888888"}>
          {`${idx() === i ? "> " : "  "}${opt.title}  ${opt.description}`}
        </text>
      ))}
      <text fg="#555555">Up/Dn Navigate Enter Cycle Tier Space Pick Model Esc Back</text>
    </box>
  );
}
