// Prompts mirror apps/macos/Sources/Views/FloatingHUDView.swift so both
// clients hand the same instructions to the assistant.

export interface Note {
  readonly timeMs: number;
  readonly text: string;
}

/** The brief's `context`: free-form instructions plus timestamped notes. */
export function implementationContext(context: string, notes: readonly Note[]): string {
  return [context.trim(), ...notes.map((note) => `[${(note.timeMs / 1000).toFixed(2)}s] ${note.text}`)]
    .filter((line) => line.length > 0)
    .join("\n");
}

export function handoffPrompt(briefId: string, isVideo: boolean): string {
  const lookup = `Use Poach MCP to call poach_read_brief with briefId ${briefId}. Verify the returned briefId matches.`;
  if (!isVideo) {
    return `${lookup} Recreate the visible UI using the screenshot, palette, and change notes. Ask about behavior that the screenshot does not show.`;
  }
  // The Linux client does not record a pointer trace yet.
  const pointer = "This media has no native pointer trace; do not assume clicks or drags that are not visible in the video or described in notes.";
  return `${lookup} Use its images and timestamped notes. ${pointer} Use the video and notes to describe visible results, and ask if behavior is ambiguous. Recreate the recorded interaction in this project. For video details, call poach_read_moment with the same briefId and timeMs.`;
}
