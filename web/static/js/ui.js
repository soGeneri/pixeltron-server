// Shared UI pieces: the confirm dialog that replaces window.confirm(), and the
// toast that confirms saves and reports errors in place of alert(). Labels come
// from data attributes on #pxt-ui (base.html), so they follow the user's locale.
(function () {
  const root = document.getElementById('pxt-ui');
  const label = (key, fallback) => (root && root.dataset[key]) || fallback;

  // pxtConfirm(message, { confirmLabel, danger }) resolves true or false.
  window.pxtConfirm = function (message, options = {}) {
    const dialog = document.getElementById('pxt-confirm');
    if (!dialog || typeof dialog.showModal !== 'function') {
      return Promise.resolve(window.confirm(message));
    }
    const ok = dialog.querySelector('[data-confirm-ok]');
    const cancel = dialog.querySelector('[data-confirm-cancel]');
    dialog.querySelector('[data-confirm-message]').textContent = message;
    ok.textContent = options.confirmLabel || (options.danger ? label('delete', 'Delete') : label('ok', 'OK'));
    ok.classList.toggle('btn-danger', !!options.danger);
    ok.classList.toggle('btn-primary', !options.danger);
    const opener = document.activeElement;

    return new Promise((resolve) => {
      const finish = (result) => {
        ok.removeEventListener('click', onOk);
        cancel.removeEventListener('click', onCancel);
        dialog.removeEventListener('close', onClose);
        if (dialog.open) dialog.close();
        if (opener && typeof opener.focus === 'function' && document.contains(opener)) opener.focus();
        resolve(result);
      };
      const onOk = () => finish(true);
      const onCancel = () => finish(false);
      const onClose = () => finish(false);
      ok.addEventListener('click', onOk);
      cancel.addEventListener('click', onCancel);
      dialog.addEventListener('close', onClose);
      dialog.showModal();
      // Destructive questions start on Cancel so Enter never deletes by accident.
      (options.danger ? cancel : ok).focus();
    });
  };

  // Any button, link or form with data-confirm asks first. data-confirm-danger
  // styles the dialog as destructive.
  function confirmThen(el, proceed) {
    const message = el.dataset.confirm;
    window.pxtConfirm(message, {
      danger: el.hasAttribute('data-confirm-danger'),
      confirmLabel: el.dataset.confirmLabel,
    }).then((yes) => {
      if (yes) proceed();
    });
  }

  document.addEventListener('click', (e) => {
    const el = e.target.closest('a[data-confirm], button[data-confirm]');
    if (!el || el.dataset.confirmed === 'true') return;
    e.preventDefault();
    e.stopPropagation();
    confirmThen(el, () => {
      el.dataset.confirmed = 'true';
      el.click();
      delete el.dataset.confirmed;
    });
  }, true);

  document.addEventListener('submit', (e) => {
    const form = e.target;
    if (!form.matches('form[data-confirm]') || form.dataset.confirmed === 'true') return;
    e.preventDefault();
    confirmThen(form, () => {
      form.dataset.confirmed = 'true';
      form.requestSubmit ? form.requestSubmit(e.submitter || undefined) : form.submit();
      delete form.dataset.confirmed;
    });
  }, true);

  // Overflow menus (<details class="pxt-more">): one open at a time, closed by
  // an outside click, by Escape, or after choosing an item.
  document.addEventListener('click', (e) => {
    document.querySelectorAll('details.pxt-more[open]').forEach((menu) => {
      const inside = menu.contains(e.target);
      const choseItem = inside && e.target.closest('button.pxt-more-item');
      if (!inside || choseItem) menu.removeAttribute('open');
    });
  });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    const menu = e.target.closest && e.target.closest('details.pxt-more[open]');
    if (menu) {
      menu.removeAttribute('open');
      menu.querySelector('summary').focus();
    }
  });

  // pxtToast(message, tone): tone is 'success' (default) or 'error'. The toast
  // region is a live region, so screen readers hear it too.
  let toastTimer = null;
  window.pxtToast = function (message, tone = 'success') {
    const toast = document.getElementById('pxt-toast');
    if (!toast) return;
    toast.textContent = message;
    toast.dataset.tone = tone;
    toast.setAttribute('role', tone === 'error' ? 'alert' : 'status');
    toast.classList.add('visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('visible'), tone === 'error' ? 6000 : 2400);
  };

  // pxtToastNext(message) shows a toast on the next page, for actions that
  // navigate away (saving a config, deleting an app).
  const NEXT_KEY = 'pxt-toast-next';
  window.pxtToastNext = function (message) {
    try { sessionStorage.setItem(NEXT_KEY, message); } catch (e) { /* storage blocked: skip the toast */ }
  };
  try {
    const pending = sessionStorage.getItem(NEXT_KEY);
    if (pending) {
      sessionStorage.removeItem(NEXT_KEY);
      window.pxtToast(pending);
    }
  } catch (e) { /* storage blocked */ }

  window.pxtSaved = () => window.pxtToast(label('saved', 'Saved'));
  window.pxtError = (message) => window.pxtToast(message || label('error', 'Something went wrong. Try again.'), 'error');
})();
