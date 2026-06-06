// Aperture mark — four corner brackets closing on a diamond core.
// Single-color SVG, recolorable via `color`.

export function Aperture({
  size = 26,
  color = "#ffffff",
}: {
  size?: number;
  color?: string;
}) {
  const TL = "M14 14 H46 V26 H26 V46 H14 Z";
  const TR = "M86 14 H54 V26 H74 V46 H86 Z";
  const BL = "M14 86 H46 V74 H26 V54 H14 Z";
  const BR = "M86 86 H54 V74 H74 V54 H86 Z";
  return (
    <svg
      viewBox="0 0 100 100"
      width={size}
      height={size}
      style={{ display: "block" }}
      aria-hidden="true"
    >
      <g fill={color}>
        <path d={TL} />
        <path d={TR} />
        <path d={BL} />
        <path d={BR} />
        <polygon points="50,37 63,50 50,63 37,50" />
      </g>
    </svg>
  );
}
