// JavaScript that runs inside the one Brave tab QuickChat created. Brave renders ChatGPT with its own live session;
// these scripts never read a cookie and never touch another tab.

/// What the launcher's tab is showing.
enum PageState: String {
    case loading
    case signIn = "signin"
    case ready

    /// Anything unexpected counts as still loading, so the launcher keeps waiting instead of showing a broken page.
    init(reported: Any?) {
        self = (reported as? String).flatMap(PageState.init(rawValue:)) ?? .loading
    }
}

/// Why the overlay went away, as reported by the page.
enum HideReason: String {
    case toggle
    case escape
    case closed
    case blur

    /// A click into another window already moved focus where the owner wants it.
    var restoresPreviousApp: Bool { self != .blur }
}

enum PageScripts {
    /// Name of the CDP binding the page calls when the overlay is hidden.
    static let hiddenBinding = "quickchatHidden"

    /// Installs the page helpers once per load and reports `loading`, `signin` or `ready`.
    /// `ready` means the composer exists and thinking effort is Instant.
    static let prepare = #"""
    (async () => {
      if (location.host !== 'chatgpt.com') return /(^|\.)openai\.com$/.test(location.host) ? 'signin' : 'loading';
      if (!window.__quickchat) {
        const q = (window.__quickchat = { win: null, reason: null });
        // The page's nodes, including its popups, live in the overlay's document while the overlay is open.
        q.root = () => (q.win && !q.win.closed ? q.win.document : document);
        q.composer = () => q.root().querySelector('div.ProseMirror[contenteditable="true"]');
        // Brave slows setTimeout in a hidden tab to one tick per second or less. MessageChannel is not slowed.
        const tick = () => new Promise(r => { const c = new MessageChannel(); c.port1.onmessage = () => r(); c.port2.postMessage(0); });
        q.until = async (test, maxMs) => {
          const end = performance.now() + maxMs;
          while (!test() && performance.now() < end) await tick();
          return test();
        };
        const effortButton = () => [...q.root().querySelectorAll('button[aria-label="Select ChatGPT model"]')].find(b => b.getBoundingClientRect().width > 0);
        const isInstant = () => /Instant/.test(effortButton()?.innerText ?? '');
        const setInstant = async () => {
          for (let attempt = 0; attempt < 3 && !isInstant(); attempt++) {
            const button = effortButton();
            if (!button) { await q.until(effortButton, 300); continue; }
            const view = button.ownerDocument.defaultView;
            for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
              button.dispatchEvent(new (type.startsWith('pointer') ? view.PointerEvent : view.MouseEvent)(type, { bubbles: true, cancelable: true, button: 0, pointerType: 'mouse' }));
            }
            const slider = () => q.root().querySelector('[role="menu"] [aria-label="Power"]');
            const step = () => q.root().querySelector('[role="menu"] [role="status"]')?.innerText ?? '';
            const opened = await q.until(slider, 1500);
            for (let i = 0; opened && i < 5 && !/^Instant/.test(step()); i++) {
              const before = step();
              slider().focus();
              slider().dispatchEvent(new view.KeyboardEvent('keydown', { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37, bubbles: true, cancelable: true }));
              await q.until(() => step() !== before, 500);
            }
            // The page's popups listen for Escape on the tab's own document.
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            await q.until(() => !q.root().querySelector('[role="menu"]'), 500);
            await q.until(isInstant, 300);
          }
          return isInstant();
        };
        let running = null;
        q.ensureInstant = () => (running ??= setInstant().finally(() => { running = null; }));
        // ChatGPT replaces the effort with the account's saved one shortly after load, so keep putting it back.
        setInterval(async () => {
          if (running || !effortButton() || isInstant()) return;
          const box = q.composer();
          const hadFocus = !!box && q.root().activeElement === box;
          await q.ensureInstant();
          if (hadFocus) box.focus();
        }, 250);
      }
      const q = window.__quickchat;
      if ([...q.root().querySelectorAll('button, a')].some(e => /^(log in|sign up)/i.test((e.innerText || '').trim()))) return 'signin';
      if (!q.composer()) return 'loading';
      return (await q.ensureInstant()) ? 'ready' : 'loading';
    })()
    """#

    /// Hides the overlay if it is showing and reports whether it was. Works in any page state.
    static let hideIfShown = #"""
    (() => {
      const q = window.__quickchat;
      if (!q?.win || q.win.closed) return false;
      q.hide('toggle');
      return true;
    })()
    """#

    /// Shows the overlay and returns `shown`. Requires a `ready` page.
    /// ChatGPT stays loaded in the tab; showing moves its live DOM into a Document Picture-in-Picture window
    /// (always on top, owned by Brave) and hiding moves it back, so the conversation and draft are never reloaded.
    static let show = #"""
    (async () => {
      const q = window.__quickchat;
      if (q.win && !q.win.closed) return 'shown';
      const w = await documentPictureInPicture.requestWindow({ width: 480, height: 640 });
      const d = w.document;
      for (const a of document.documentElement.attributes) d.documentElement.setAttribute(a.name, a.value);
      for (const a of document.body.attributes) d.body.setAttribute(a.name, a.value);
      const isStyle = n => n.nodeType === 1 && (n.matches('style') || n.matches('link[rel="stylesheet"]'));
      for (const n of document.head.children) if (isStyle(n)) d.head.append(n.cloneNode(true));
      d.body.append(...document.body.childNodes);
      // Popups and late stylesheets are still created in the tab; carry them over.
      const bodyObserver = new MutationObserver(records => {
        for (const r of records) for (const n of r.addedNodes) if (n.parentNode === document.body) d.body.append(n);
      });
      bodyObserver.observe(document.body, { childList: true });
      const headObserver = new MutationObserver(records => {
        for (const r of records) for (const n of r.addedNodes) if (isStyle(n)) d.head.append(n.cloneNode(true));
      });
      headObserver.observe(document.head, { childList: true });
      q.win = w;
      q.reason = null;
      q.hide = reason => { q.reason = reason; w.close(); };
      w.addEventListener('pagehide', () => {
        bodyObserver.disconnect();
        headObserver.disconnect();
        document.body.append(...d.body.childNodes);
        q.win = null;
        window.quickchatHidden?.(q.reason ?? 'closed');
      });
      // The page's popups listen for outside presses and Escape on the tab's own document; repeat them there.
      w.addEventListener('pointerdown', e => document.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, button: e.button, pointerType: e.pointerType })));
      w.addEventListener('keydown', e => {
        if (e.key !== 'Escape' || e.isComposing) return;
        if (d.querySelector('[role="menu"], [role="dialog"], [role="listbox"]')) {
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
          return;
        }
        q.hide('escape');
      }, true);
      q.composer()?.focus();
      // The overlay is only useful with keyboard focus, and click-away can only be noticed once it has it.
      if (!(await q.until(() => w.closed || d.hasFocus(), 1500)) || w.closed) {
        if (!w.closed) q.hide('closed');
        throw new Error('The overlay did not get keyboard focus.');
      }
      w.addEventListener('blur', () => w.setTimeout(() => { if (!w.closed && !d.hasFocus()) q.hide('blur'); }, 0));
      return 'shown';
    })()
    """#

    /// Presses ChatGPT's own New chat control in the launcher's tab and puts the cursor in the composer.
    static let newChat = #"""
    (async () => {
      const q = window.__quickchat;
      const controls = [...q.root().querySelectorAll('button, a')].filter(e => (e.getAttribute('aria-label') || e.innerText || '').trim() === 'New chat');
      const control = controls.find(e => e.getBoundingClientRect().width > 0) ?? controls[0];
      if (!control) throw new Error('ChatGPT has no New chat control on this page');
      control.click();
      await q.until(q.composer, 3000);
      q.composer()?.focus();
      return true;
    })()
    """#
}
