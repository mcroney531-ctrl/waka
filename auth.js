// Sign-in for the Documentary Acquisitions Ledger (index.html + brainstorm.html).
//
// The arch_* tables and the brainstorm edge function are moving to owner-only
// access (see db/README.md). This file owns the Supabase client so both pages
// share one session, and mounts a small account button + sign-in dialog.
//
// - Email + password on the shared owner account; sign-ups are off.
// - Sessions persist in this site's storage and refresh themselves, so an
//   installed PWA signs in once per device.
// - Sign-out is scope 'local': the owner account is shared with other apps and
//   devices, and a global sign-out would revoke all of them.
// - If a session disappears without a deliberate sign-out, the button turns red
//   and says so; a network failure while refreshing is shown as "offline"
//   instead, and the page reloads once the session comes back.
// - Never logs passwords or tokens.
(function () {
  'use strict';
  var STORAGE_KEY = 'waka-auth';
  var EXPECT_KEY = 'waka_expect_session';

  var sb = null;
  var state = { user: null, lost: false, pending: false, checked: false };
  var signingOut = false;
  var dialog = null;

  function expectSession(on) {
    try {
      if (on === undefined) return localStorage.getItem(EXPECT_KEY) === '1';
      if (on) localStorage.setItem(EXPECT_KEY, '1'); else localStorage.removeItem(EXPECT_KEY);
    } catch (e) { return false; }
  }

  function applySession(session) {
    state.user = session ? session.user : null;
    if (state.user) { state.lost = false; expectSession(true); }
    render();
  }

  function init(url, key) {
    sb = window.supabase.createClient(url, key, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false,   // password sign-in only; no redirect links
        storageKey: STORAGE_KEY,
      },
    });

    sb.auth.onAuthStateChange(function (event, session) {
      if (event === 'SIGNED_OUT' && !signingOut && state.user) state.lost = true;
      // Refreshed after a network failure at load: data loaded without the
      // session, so load again now that it's back.
      if (state.pending && session) { state.pending = false; location.reload(); return; }
      applySession(session);
    });

    sb.auth.getSession().then(function (res) {
      state.checked = true;
      if (res.error && window.supabase.isAuthRetryableFetchError(res.error)) {
        state.pending = true;   // session kept; supabase-js retries in the background
        render();
        return;
      }
      applySession(res.data.session);
      if (!res.data.session && expectSession()) { state.lost = true; render(); }
    }).catch(function () { state.checked = true; render(); console.warn('Auth check failed'); });

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount);
    else mount();
    return sb;
  }

  // ---- UI -----------------------------------------------------------------
  var button = null;

  function css(el, styles) { for (var k in styles) el.style[k] = styles[k]; return el; }

  function mount() {
    if (button) return;
    button = css(document.createElement('button'), {
      position: 'fixed', top: '10px', right: '10px', zIndex: '1000',
      padding: '5px 11px', borderRadius: '2px', cursor: 'pointer',
      fontFamily: "'IBM Plex Mono', monospace", fontSize: '11px', letterSpacing: '0.04em',
      color: 'var(--ink, #221F1A)', background: 'var(--paper, #EDE6D6)',
      border: '1px solid var(--border, rgba(34,31,26,0.3))',
    });
    button.id = 'wakaAccount';
    button.type = 'button';
    button.setAttribute('aria-haspopup', 'dialog');
    button.onclick = openDialog;
    document.body.appendChild(button);
    render();
  }

  function render() {
    if (!button) return;
    var label, warn = false;
    if (state.user) label = '✓ Signed in';
    else if (state.pending) label = 'Offline — sign-in will resume';
    else if (state.lost) { label = '⚠ Signed out — sign in again'; warn = true; }
    else label = state.checked ? 'Sign in' : 'Account';
    button.textContent = label;
    button.style.background = warn ? 'var(--red, #A13D2B)' : 'var(--paper, #EDE6D6)';
    button.style.color = warn ? '#fff' : 'var(--ink, #221F1A)';
  }

  function closeDialog() { if (dialog) { dialog.remove(); dialog = null; } }

  function openDialog() {
    closeDialog();
    dialog = css(document.createElement('div'), {
      position: 'fixed', inset: '0', zIndex: '1001', background: 'rgba(34,31,26,0.45)',
      display: 'flex', alignItems: 'flex-start', justifyContent: 'center', paddingTop: '12vh',
    });
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    dialog.onclick = function (e) { if (e.target === dialog) closeDialog(); };

    var card = css(document.createElement('div'), {
      width: 'min(360px, calc(100vw - 32px))', background: 'var(--paper, #EDE6D6)',
      border: '1px solid var(--border, rgba(34,31,26,0.3))', padding: '18px',
      fontFamily: "'Lora', serif", color: 'var(--ink, #221F1A)', boxShadow: '0 8px 30px rgba(0,0,0,0.2)',
    });
    dialog.appendChild(card);

    var h = css(document.createElement('div'), { fontFamily: "'Special Elite', monospace", fontSize: '18px', marginBottom: '12px' });
    card.appendChild(h);

    function btn(text, primary) {
      var b = css(document.createElement('button'), {
        width: '100%', padding: '9px', marginTop: '8px', cursor: 'pointer',
        fontFamily: "'IBM Plex Mono', monospace", fontSize: '12px',
        border: '1px solid var(--ink, #221F1A)',
        background: primary ? 'var(--ink, #221F1A)' : 'transparent',
        color: primary ? 'var(--paper, #EDE6D6)' : 'var(--ink, #221F1A)',
      });
      b.textContent = text;
      return b;
    }

    if (state.user) {
      h.textContent = 'Account';
      var p = document.createElement('p');
      p.appendChild(document.createTextNode('Signed in as '));
      var strong = document.createElement('strong');
      strong.textContent = state.user.email || 'your account';   // text, never HTML
      p.appendChild(strong);
      p.appendChild(document.createTextNode('. You stay signed in on this device until you sign out.'));
      card.appendChild(p);
      var out = btn('Sign out', false);
      out.id = 'wakaSignOut';
      out.onclick = signOut;
      card.appendChild(out);
    } else {
      h.textContent = 'Sign in';
      var form = document.createElement('form');
      form.noValidate = true;
      function input(id, type, ac, ph) {
        var i = css(document.createElement('input'), {
          display: 'block', width: '100%', boxSizing: 'border-box', padding: '8px', marginBottom: '8px',
          fontFamily: "'IBM Plex Mono', monospace", fontSize: '13px',
          border: '1px solid var(--border, rgba(34,31,26,0.3))', background: '#fff',
        });
        i.id = id; i.type = type; i.autocomplete = ac; i.placeholder = ph;
        return i;
      }
      var email = input('wakaEmail', 'email', 'username', 'Email');
      email.inputMode = 'email';
      var pw = input('wakaPassword', 'password', 'current-password', 'Password');
      var err = css(document.createElement('div'), { color: 'var(--red, #A13D2B)', fontSize: '13px', minHeight: '18px' });
      err.id = 'wakaError';
      err.setAttribute('role', 'alert');
      var go = btn('Sign in', true);
      go.id = 'wakaSignIn';
      go.type = 'submit';
      form.appendChild(email); form.appendChild(pw); form.appendChild(err); form.appendChild(go);
      if (state.lost) {
        var stay = btn('Continue signed out', false);
        stay.id = 'wakaStaySignedOut';
        stay.type = 'button';
        stay.onclick = function () { expectSession(false); state.lost = false; render(); closeDialog(); };
        form.appendChild(stay);
      }
      form.onsubmit = function (e) {
        e.preventDefault();
        err.textContent = '';
        var em = email.value.trim(), p2 = pw.value;
        if (!em || !p2) { err.textContent = 'Enter your email and password.'; return; }
        go.disabled = true; go.textContent = 'Signing in…';
        sb.auth.signInWithPassword({ email: em, password: p2 }).then(function (res) {
          if (res.error) {
            err.textContent = res.error.message || 'Sign-in failed.';   // server message only
            go.disabled = false; go.textContent = 'Sign in';
            return;
          }
          location.reload();   // reload so every query runs under the session
        });
      };
      card.appendChild(form);
      setTimeout(function () { email.focus(); }, 0);
    }
    document.body.appendChild(dialog);
  }

  function signOut() {
    signingOut = true;
    expectSession(false);
    sb.auth.signOut({ scope: 'local' }).then(function () { location.reload(); });
  }

  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeDialog(); });

  window.WakaAuth = { init: init };
})();
