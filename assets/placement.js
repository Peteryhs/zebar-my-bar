// Geometry is in logical pixels; Zebar scales px values for the selected display.
export function anchoredPlacement({ rect, barBottom = rect.bottom, barPosition, monitor, width, height, align = 'center', gap = 8 }) {
  const scale = monitor.scaleFactor || 1;
  const displayWidth = monitor.size.width / scale;
  const displayHeight = monitor.size.height / scale;
  const panelWidth = Math.min(width, Math.max(1, displayWidth - 16));
  const tileLeft = (barPosition.x - monitor.position.x) / scale + rect.left;
  const desiredLeft = align === 'start' ? tileLeft : tileLeft + (rect.width - panelWidth) / 2;
  const left = Math.max(8, Math.min(displayWidth - panelWidth - 8, desiredLeft));
  // Measure from the bar surface, not the shorter button inside it. Together
  // with the panel's 8px inset this leaves a consistent 16px visible gap.
  const top = (barPosition.y - monitor.position.y) / scale + Math.max(barBottom, rect.bottom) + gap;
  return {
    anchor: 'top_left',
    offsetX: `${Math.round(left)}px`,
    offsetY: `${Math.round(top)}px`,
    width: `${Math.round(panelWidth)}px`,
    height: `${Math.round(Math.min(height, Math.max(1, displayHeight - top - 8)))}px`,
    monitorSelection: { type: 'name', match: monitor.name },
    dockToEdge: { enabled: false, edge: null, windowMargin: '0px' },
  };
}
