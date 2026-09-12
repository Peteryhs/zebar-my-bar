/*
 * Keeps a panel's window the same size as the card inside it.
 *
 * The card is sized by its contents (see styles.css), which is what stops the
 * dead space under the last row. The window, though, comes from the preset in
 * zpack.json, and it has to be big enough for the fullest version of the panel:
 * the media panel with an artist and an album, the storage panel with a drive
 * plugged in. So on a normal day the window was taller than the card, and the
 * difference was a strip of window with nothing drawn on it.
 *
 * That strip was the reason dismissing took two clicks. The guard decides "did
 * that click land outside the panel" from the window rectangle, and a click on
 * the strip is inside it, so the guard left the panel alone and it was up to the
 * page to notice. Which it did not, reliably.
 *
 * Rather than teach the guard where the card is, the window is made to agree with
 * the card, and the geometry the guard already uses becomes correct.
 *
 * This is not the self-resizing that the panels are warned off: that showed the
 * panel clipped and then jumping to full size, because the window started too
 * small and grew after the content had been drawn. Here the card's layout never
 * depends on the window height, so the card is drawn correctly from the first
 * frame and never moves. The only thing that changes is where the invisible
 * bottom edge of the window sits.
 */

export function fitWindowToCard(widget, selector = '.panel') {
  const card = document.querySelector(selector);

  if (!card) return;

  const tauriWindow = widget.tauriWindow;
  let lastHeight = 0;

  function fit() {
    const rect = card.getBoundingClientRect();

    // rect.top is the body margin, counted twice so the gap under the card
    // matches the gap above it.
    const height = Math.ceil(rect.top + rect.height + rect.top);

    // The window width is left alone: it is the preset's, and the card fills it.
    const width = document.documentElement.clientWidth;

    if (height === lastHeight || height <= 0) return;

    lastHeight = height;

    // A plain object rather than LogicalSize, which moved modules between Tauri
    // versions. setSize only looks at these three fields.
    tauriWindow
      .setSize({ type: 'Logical', width, height })
      .catch(err => console.warn('could not size the panel window:', err));
  }

  fit();

  /*
   * Panels fill in after they open: a provider's first output, the specs script
   * coming back, a long name wrapping onto a second line. The window follows.
   * Growing happens in the same frame as the content that caused it, so there is
   * nothing to see.
   */
  if (typeof ResizeObserver === 'function') {
    new ResizeObserver(fit).observe(card);
  }
}
