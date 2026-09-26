"use client";
// A text field that accepts only a decimal number with at most `maxDec` decimals.
import type { InputHTMLAttributes } from "react";
import { filterDecimal } from "@/lib/ui";

type Props = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  "onChange" | "value"
> & {
  value: string;
  maxDec?: number;
  onValue: (v: string) => void;
};

export default function DecimalInput({
  value,
  maxDec,
  onValue,
  ...rest
}: Props) {
  return (
    <input
      type="text"
      inputMode="decimal"
      autoComplete="off"
      {...rest}
      value={value}
      onChange={(e) => onValue(filterDecimal(e.target.value, maxDec))}
    />
  );
}
