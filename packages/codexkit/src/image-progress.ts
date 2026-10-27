/** Presentation-only time estimate; not provider progress or an ETA. Never returns 100. */
export function estimateImageGenerationProgress(elapsedSeconds: number): number {
  if (!Number.isFinite(elapsedSeconds)) return elapsedSeconds > 0 ? 99 : 3;
  const time = Math.max(0, elapsedSeconds) / 45;
  const anchors = [[0, 3], [0.1, 25], [0.55, 58], [0.85, 88], [1, 90]] as const;
  for (let index = 1; index < anchors.length; index++) {
    const [startTime, startValue] = anchors[index - 1]!;
    const [endTime, endValue] = anchors[index]!;
    if (time <= endTime) {
      const fraction = (time - startTime) / (endTime - startTime);
      return Math.floor(startValue + fraction * (endValue - startValue));
    }
  }
  return Math.min(99, Math.floor(90 + 10 * (1 - Math.exp(-1.5 * (time - 1)))));
}
