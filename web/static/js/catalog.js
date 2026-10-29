// Add-app catalog: one toolbar (search, category chips, sort, toggles) filters
// every group; choosing a tile opens the details panel, which installs.
(function () {
  const root = document.querySelector('[data-catalog]');
  if (!root) return;

  const PAGE_SIZE = 48;
  // System apps keep the original key so existing saved sorts carry over.
  const SORT_KEY = 'tronbyt_app_sort_type';

  const labelsEl = document.getElementById('catalog_labels');
  const label = (key) => (labelsEl && labelsEl.dataset[key]) || '';

  const search = document.getElementById('catalog_search');
  const sort = document.getElementById('catalog_sort');
  const hideInstalled = document.getElementById('catalog_hide_installed');
  const showBroken = document.getElementById('catalog_show_broken');
  const chipsEl = root.querySelector('[data-category-chips]');
  const countEl = root.querySelector('[data-result-count]');
  const emptyEl = root.querySelector('[data-catalog-empty]');
  const groups = Array.from(root.querySelectorAll('[data-catalog-group]')).map((el) => ({
    el,
    grid: el.querySelector('.app-grid'),
    count: el.querySelector('[data-group-count]'),
    more: el.querySelector('[data-show-more]'),
    items: Array.from(el.querySelectorAll('.app-item')),
    limit: PAGE_SIZE,
  }));

  let category = '';

  // ---- Categories become chips, in alphabetical order --------------------
  const categories = new Set();
  groups.forEach((g) => g.items.forEach((item) => {
    const c = item.dataset.category;
    if (c) categories.add(c);
  }));
  Array.from(categories).sort().forEach((c) => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'catalog-cat';
    chip.dataset.category = c.toLowerCase();
    chip.setAttribute('aria-pressed', 'false');
    chip.textContent = c.charAt(0).toUpperCase() + c.slice(1);
    chipsEl.appendChild(chip);
  });
  if (!categories.size) chipsEl.hidden = true;

  // Each chip carries a live count, filled in by render().
  const chipCounts = new Map();
  chipsEl.querySelectorAll('.catalog-cat').forEach((chip) => {
    const n = document.createElement('span');
    n.className = 'catalog-cat-count';
    chip.appendChild(n);
    chipCounts.set(chip.dataset.category, { chip, n });
  });

  // Fade whichever edge of the chip row has more chips past it.
  function updateChipEdges() {
    const max = chipsEl.scrollWidth - chipsEl.clientWidth;
    chipsEl.toggleAttribute('data-more-start', chipsEl.scrollLeft > 1);
    chipsEl.toggleAttribute('data-more-end', chipsEl.scrollLeft < max - 1);
  }
  chipsEl.addEventListener('scroll', updateChipEdges, { passive: true });
  window.addEventListener('resize', updateChipEdges);

  chipsEl.addEventListener('click', (e) => {
    const chip = e.target.closest('.catalog-cat');
    if (!chip) return;
    category = chip.dataset.category;
    chipsEl.querySelectorAll('.catalog-cat').forEach((c) => c.setAttribute('aria-pressed', c === chip ? 'true' : 'false'));
    resetPaging();
    render();
  });

  // ---- Sorting ------------------------------------------------------------
  try {
    const saved = localStorage.getItem(SORT_KEY);
    if (saved && Array.from(sort.options).some((o) => o.value === saved)) sort.value = saved;
  } catch (e) { /* storage blocked: default sort */ }

  const parseDate = (s) => {
    if (!s) return 0;
    const t = Date.parse(s.replace(' ', 'T'));
    return Number.isNaN(t) ? 0 : t;
  };
  const name = (item) => (item.dataset.name || '').toLowerCase();

  function compare(a, b) {
    const byName = name(a).localeCompare(name(b));
    switch (sort.value) {
      case 'installs':
        // Apps without a count sort after every counted app.
        return Number(b.dataset.installs || -1) - Number(a.dataset.installs || -1) || byName;
      case 'alphabetical':
        return byName;
      case 'rev-alphabetical':
        return -byName;
      case 'newest':
        return parseDate(b.dataset.published || b.dataset.date) - parseDate(a.dataset.published || a.dataset.date) || byName;
      case 'last-updated':
        return parseDate(b.dataset.updated || b.dataset.date) - parseDate(a.dataset.updated || a.dataset.date) || byName;
      default: {
        // Installed apps first, then A-Z.
        const ia = a.dataset.installed === 'true';
        const ib = b.dataset.installed === 'true';
        return ia === ib ? byName : (ia ? -1 : 1);
      }
    }
  }

  // ---- Filtering ----------------------------------------------------------
  // Everything except the category; the chips count against this.
  function matchesBase(item, query) {
    if (hideInstalled.checked && item.dataset.installed === 'true') return false;
    if (!showBroken.checked && item.dataset.broken === 'true') return false;
    if (!query) return true;
    if (query.startsWith('@')) {
      return (item.dataset.author || '').toLowerCase().includes(query.slice(1));
    }
    const d = item.dataset;
    return [d.name, d.summary, d.desc, d.tags, d.category].some((v) => (v || '').toLowerCase().includes(query));
  }

  const categoryOf = (item) => (item.dataset.category || '').toLowerCase();

  const fill = (text, values) => Object.entries(values).reduce((s, [k, v]) => s.split(k).join(v), text);
  const countText = (n) => (n === 1 ? label('appsOne') : fill(label('appsMany'), { __N__: n }));

  function render() {
    const query = search.value.trim().toLowerCase();
    let total = 0;
    let shown = 0;
    const perCategory = new Map([['', 0]]);

    groups.forEach((g) => {
      const base = g.items.filter((item) => matchesBase(item, query));
      base.forEach((item) => {
        const c = categoryOf(item);
        perCategory.set(c, (perCategory.get(c) || 0) + 1);
        perCategory.set('', perCategory.get('') + 1);
      });
      const visible = base.filter((item) => !category || categoryOf(item) === category).sort(compare);
      const fragment = document.createDocumentFragment();
      visible.forEach((item, i) => {
        item.hidden = i >= g.limit;
        fragment.appendChild(item);
      });
      g.items.forEach((item) => {
        if (!visible.includes(item)) {
          item.hidden = true;
          fragment.appendChild(item);
        }
      });
      g.grid.appendChild(fragment);

      const left = visible.length - Math.min(g.limit, visible.length);
      g.more.hidden = left <= 0;
      g.more.textContent = fill(label('showMore'), { __N__: Math.min(left, PAGE_SIZE) });
      g.count.textContent = countText(visible.length);
      g.el.hidden = visible.length === 0;
      total += visible.length;
      shown += Math.min(g.limit, visible.length);
    });

    chipCounts.forEach(({ chip, n }, c) => {
      const count = perCategory.get(c) || 0;
      n.textContent = count;
      chip.classList.toggle('is-empty', count === 0);
    });
    updateChipEdges();

    emptyEl.hidden = total > 0;
    countEl.textContent = shown < total
      ? fill(label('showing'), { __SHOWN__: shown, __N__: total })
      : countText(total);
  }

  // Tiles keep clear of the sticky toolbar when scrolled or focused into view.
  const toolbar = root.querySelector('.catalog-toolbar');
  const groupsEl = root.querySelector('.catalog-groups');
  function measureToolbar() {
    const sticky = getComputedStyle(toolbar).position === 'sticky';
    root.style.setProperty('--catalog-toolbar-h', sticky ? (toolbar.offsetHeight + 24) + 'px' : '0px');
  }
  measureToolbar();
  window.addEventListener('resize', measureToolbar);

  // A new filter brings the top of the results back into view.
  function resetPaging() {
    groups.forEach((g) => { g.limit = PAGE_SIZE; });
    const y = groupsEl.getBoundingClientRect().top + window.scrollY - toolbar.offsetHeight - 24;
    if (window.scrollY > y) window.scrollTo({ top: y });
  }

  let searchTimer = null;
  search.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { resetPaging(); render(); }, 150);
  });
  search.addEventListener('keydown', (e) => {
    // Enter in the search box must not submit the install form.
    if (e.key === 'Enter') e.preventDefault();
    if (e.key === 'Escape' && search.value) {
      e.preventDefault();
      search.value = '';
      resetPaging();
      render();
    }
  });
  // "/" jumps to the search from anywhere on the page that isn't a text field.
  document.addEventListener('keydown', (e) => {
    if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey || sheetOpen()) return;
    const t = e.target;
    if (t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) return;
    e.preventDefault();
    search.focus();
    search.select();
  });
  sort.addEventListener('change', () => {
    try { localStorage.setItem(SORT_KEY, sort.value); } catch (e) { /* storage blocked */ }
    render();
  });
  [hideInstalled, showBroken].forEach((box) => box.addEventListener('change', () => { resetPaging(); render(); }));

  groups.forEach((g) => g.more.addEventListener('click', () => {
    const firstNew = g.items.filter((i) => !i.hidden).length;
    g.limit += PAGE_SIZE;
    render();
    // Keep keyboard users where the new tiles start.
    const next = Array.from(g.grid.querySelectorAll('.app-item:not([hidden])'))[firstNew];
    if (next) next.focus();
  }));

  root.querySelector('[data-clear-filters]').addEventListener('click', () => {
    search.value = '';
    hideInstalled.checked = false;
    showBroken.checked = false;
    chipsEl.querySelector('.catalog-cat[data-category=""]').click();
    search.focus();
  });

  // ---- The stage ----------------------------------------------------------
  // Wide screens show the chosen app in a sticky column beside the grid;
  // narrow ones raise the same panel as a bottom sheet.
  const detail = document.getElementById('catalog_detail');
  const scrim = root.querySelector('.catalog-stage-scrim');
  const sheetQuery = window.matchMedia('(max-width: 1000px)');
  const sheetOpen = () => detail.hasAttribute('data-open');
  const $ = (sel) => detail.querySelector(sel);
  const install = $('[data-detail-install]');
  const delBtn = $('[data-detail-delete]');
  const markBtn = $('[data-detail-mark-broken]');
  const unmarkBtn = $('[data-detail-unmark-broken]');
  let current = null;

  function chip(text, cls) {
    const span = document.createElement('span');
    span.className = 'catalog-chip' + (cls ? ' ' + cls : '');
    span.textContent = text;
    return span;
  }

  function spec(dl, term, value) {
    if (!value) return;
    const dt = document.createElement('dt');
    dt.textContent = term;
    const dd = document.createElement('dd');
    dd.textContent = value;
    dl.append(dt, dd);
  }

  function openDetail(item) {
    if (current) current.setAttribute('aria-pressed', 'false');
    current = item;
    item.setAttribute('aria-pressed', 'true');
    const d = item.dataset;
    const broken = d.broken === 'true';

    const screen = $('[data-detail-screen]');
    screen.classList.remove('is-2x', 'is-square');
    const img = document.createElement('img');
    img.alt = '';
    img.width = 64;
    img.height = 32;
    img.src = item.querySelector('img').src;
    screen.replaceChildren(img);

    $('[data-detail-name]').textContent = d.name;
    $('[data-detail-summary]').textContent = d.summary || '';
    $('[data-detail-summary]').hidden = !d.summary;
    // Only show the long description when it says more than the summary.
    const desc = d.desc && d.desc !== d.summary ? d.desc : '';
    $('[data-detail-desc]').textContent = desc;
    $('[data-detail-desc]').hidden = !desc;

    const chips = $('[data-detail-chips]');
    chips.replaceChildren();
    if (d.supports2x === 'true') chips.append(chip(label('supports2x')));
    if (d.square === 'true') chips.append(chip(label('square')));
    chips.hidden = !chips.children.length;

    const specs = $('[data-detail-specs]');
    specs.replaceChildren();
    spec(specs, label('by'), d.author);
    spec(specs, label('category'), d.category ? d.category.charAt(0).toUpperCase() + d.category.slice(1) : '');
    spec(specs, label('installs'), d.installsLabel);
    spec(specs, label('updated'), (d.updated || d.date || '').split(/[ T]/)[0]);
    spec(specs, label('tags'), (d.tags || '').split(',').filter(Boolean).join(', '));

    $('[data-detail-installed]').hidden = d.installed !== 'true' || broken;
    const brokenNote = $('[data-detail-broken]');
    brokenNote.hidden = !broken;
    brokenNote.textContent = broken ? (d.brokenReason || '') : '';
    install.disabled = broken;

    // Upload and repo maintenance actions, for the apps they apply to.
    const admin = $('[data-detail-admin]');
    let anyAdmin = false;
    if (d.deleteUrl) {
      delBtn.hidden = false;
      delBtn.setAttribute('formaction', d.deleteUrl);
      delBtn.dataset.confirm = fill(detail.dataset.deleteConfirm, { __NAME__: d.name });
      anyAdmin = true;
    } else {
      delBtn.hidden = true;
    }
    if (markBtn) {
      markBtn.hidden = broken;
      unmarkBtn.hidden = !broken;
      anyAdmin = true;
    }
    admin.hidden = !anyAdmin;

    detail.classList.add('has-app');
    $('[data-stage-empty]').hidden = true;
    $('[data-stage-content]').hidden = false;
    if (sheetQuery.matches) {
      detail.toggleAttribute('data-open', true);
      scrim.hidden = false;
      (broken ? $('.catalog-detail-close') : install).focus();
    } else {
      // Start each new app at the top of the stage.
      detail.scrollTop = 0;
    }
  }

  function closeSheet() {
    if (!sheetOpen()) return;
    detail.removeAttribute('data-open');
    scrim.hidden = true;
    if (current && document.contains(current)) current.focus();
  }

  root.addEventListener('click', (e) => {
    const item = e.target.closest('.app-item');
    if (item && root.contains(item)) openDetail(item);
  });

  root.querySelectorAll('[data-detail-close]').forEach((b) => b.addEventListener('click', closeSheet));
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && sheetOpen()) closeSheet();
  });
  // Widening the window turns the sheet back into the side column.
  sheetQuery.addEventListener('change', () => {
    if (!sheetQuery.matches) {
      detail.removeAttribute('data-open');
      scrim.hidden = true;
    }
  });

  install.addEventListener('click', () => {
    if (!current) return;
    document.getElementById('selected_app').value = current.dataset.value;
    document.getElementById('selected_app_path').value = current.dataset.path;
    document.getElementById('uinterval').value = current.dataset.recommendedInterval || 10;
    install.disabled = true;
    document.getElementById('main_form').submit();
  });

  if (markBtn) {
    const toggleBroken = (fn, key) => (e) => fn(
      current.dataset.fileName, current.dataset.packageName, e,
      fill(detail.dataset[key], { __NAME__: current.dataset.fileName }));
    markBtn.addEventListener('click', toggleBroken(window.markAppAsBroken, 'markBrokenConfirm'));
    unmarkBtn.addEventListener('click', toggleBroken(window.unmarkAppAsBroken, 'unmarkBrokenConfirm'));
  }

  render();
})();
