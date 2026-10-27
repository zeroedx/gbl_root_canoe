(() => {
  'use strict';

  const i18n = window.BlFlasherI18n;
  const t = (key, values) => (i18n ? i18n.t(key, values) : key);

  const state = {
    confirmStep: 0,
    moduleDir: '',
    scriptPath: '',
    status: null,
    pollTimer: null,
    prevStatusRaw: '',
    prevTaskId: '',
    initError: null,
  };

  const el = (id) => document.getElementById(id);
  const elements = {
    statusText: el('statusText'),
    stateChip: el('stateChip'),
    updatedAt: el('updatedAt'),
    notice: el('notice'),
    deviceName: el('deviceName'),
    modelName: el('modelName'),
    currentSlot: el('currentSlot'),
    targetSlot: el('targetSlot'),
    moduleVersion: el('moduleVersion'),
    appTitle: el('appTitle'),
    logOutput: el('logOutput'),
    flashButton: el('flashButton'),
    clearLogButton: el('clearLogButton'),
    refreshButton: el('refresh'),
    langButton: el('langButton'),
    langLabel: el('langLabel'),
    confirmModal: el('confirmModal'),
    confirmText: el('confirmText'),
    nextConfirmButton: el('nextConfirmButton'),
    cancelConfirmButton: el('cancelConfirmButton'),
    updateEfispCheckbox: el('updateEfispCheckbox'),
    debugModeCheckbox: el('debugModeCheckbox'),
    feedback: el('feedback'),
  };

  // ---- module manager bridge (KernelSU / APatch style) ----
  function getBridge() {
    return globalThis.ksu || window.ksu || null;
  }

  const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;

  function toast(message) {
    getBridge()?.toast?.(message);
    if (elements.feedback) elements.feedback.textContent = message;
  }

  function moduleInfo() {
    const bridge = getBridge();
    if (!bridge?.moduleInfo) throw new Error(t('toasts.notInWebui'));
    const raw = bridge.moduleInfo();
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  }

  function extractStdout(raw) {
    if (raw == null) return '';
    if (typeof raw === 'string') {
      try {
        const obj = JSON.parse(raw);
        if (typeof obj?.stdout === 'string') return obj.stdout;
        if (typeof obj?.out === 'string') return obj.out;
      } catch {}
      return raw;
    }
    if (typeof raw?.stdout === 'string') return raw.stdout;
    if (typeof raw?.out === 'string') return raw.out;
    return String(raw);
  }

  function exec(command) {
    const bridge = getBridge();
    if (!bridge?.exec) throw new Error(t('toasts.execUnavailable'));
    return extractStdout(bridge.exec(command));
  }

  function runScript(action, arg) {
    const parts = [`MODDIR=${shellQuote(state.moduleDir)}`, 'sh', shellQuote(state.scriptPath), action];
    if (arg) parts.push(shellQuote(arg));
    return exec(parts.join(' ')).replace(/\t/g, '\n');
  }

  function parseKeyValueOutput(output) {
    const info = {};
    for (const line of String(output).split(/\r?\n/)) {
      if (!line) continue;
      const eq = line.indexOf('=');
      if (eq > 0) info[line.slice(0, eq)] = line.slice(eq + 1);
    }
    return info;
  }

  // Map the script's raw state to a UI state. A run with no live process and a
  // "running" record was interrupted, so it must not be shown as still running.
  function uiState(status) {
    if (status.RUNNING === '1') return 'running';
    if (status.STALE === '1') return 'unknown';
    switch (status.STATE) {
      case 'success': return 'success';
      case 'error': return 'failed';
      case 'warning': return 'waiting';
      case 'running': return 'unknown';
      default: return 'idle';
    }
  }

  function renderStatus(status) {
    state.status = status;

    const currentSlot = status.CURRENT_SLOT || '';
    const targetSlot = status.TARGET_SLOT || '';
    const ui = uiState(status);
    const label = t('state' + ui.charAt(0).toUpperCase() + ui.slice(1));

    elements.stateChip.textContent = label;
    elements.stateChip.dataset.state = ui;

    elements.statusText.textContent =
      currentSlot && targetSlot
        ? t('slotLine', { current: currentSlot, target: targetSlot })
        : t('slotUnknown');

    const updated = status.UPDATED_AT || '';
    const message = status.STATE && status.STATE !== 'idle' ? status.MESSAGE || '' : '';
    elements.updatedAt.textContent = [message, updated ? t('updatedAt', { time: updated }) : t('never')]
      .filter(Boolean)
      .join(' · ');

    elements.deviceName.textContent = status.DEVICE || t('unknown');
    elements.modelName.textContent = status.MODEL || t('unknown');
    elements.currentSlot.textContent = currentSlot || t('unknown');
    elements.targetSlot.textContent = targetSlot || t('unknown');
    elements.moduleVersion.textContent = status.MODULE_VERSION || t('unknown');
    if (elements.appTitle) elements.appTitle.textContent = status.MODULE_NAME || t('title');

    // A task id that changed under us means a run was started elsewhere (for
    // example another WebUI tab); pull the fresh log immediately.
    if (status.TASK_ID && status.TASK_ID !== state.prevTaskId) {
      if (state.prevTaskId) refreshLog();
      state.prevTaskId = status.TASK_ID;
    }

    if (ui === 'unknown') {
      elements.notice.textContent = t('staleHint');
      elements.notice.hidden = false;
    } else if (ui === 'success') {
      elements.notice.textContent = t('rebootHint');
      elements.notice.hidden = false;
    } else {
      elements.notice.hidden = true;
      elements.notice.textContent = '';
    }

    const busy = status.RUNNING === '1';
    const slotsKnown = Boolean(currentSlot && targetSlot);
    elements.flashButton.disabled = busy || !slotsKnown || Boolean(state.initError);
    elements.clearLogButton.disabled = busy || Boolean(state.initError);
  }

  function renderStatusError(message) {
    elements.stateChip.textContent = t('stateUnreachable');
    elements.stateChip.dataset.state = 'failed';
    elements.statusText.textContent = message;
    elements.flashButton.disabled = true;
    elements.clearLogButton.disabled = true;
  }

  function refreshStatus() {
    try {
      const raw = runScript('status');
      if (raw === state.prevStatusRaw) return state.status;
      state.prevStatusRaw = raw;
      const status = parseKeyValueOutput(raw);
      renderStatus(status);
      return status;
    } catch (error) {
      renderStatusError(error.message);
      return null;
    }
  }

  function refreshLog() {
    try {
      const log = runScript('tail', '200').trim();
      elements.logOutput.textContent = log || t('logEmpty');
      elements.logOutput.scrollTop = elements.logOutput.scrollHeight;
    } catch (error) {
      elements.logOutput.textContent = error.message;
    }
  }

  // ---- confirmation flow ----
  function closeConfirmModal() {
    state.confirmStep = 0;
    elements.confirmModal.classList.add('hidden');
    elements.confirmModal.setAttribute('aria-hidden', 'true');
  }

  function openConfirmModal() {
    const targetSlot = state.status?.TARGET_SLOT || '?';
    const currentSlot = state.status?.CURRENT_SLOT || '?';
    const withEfisp = Boolean(elements.updateEfispCheckbox?.checked);
    const debugMode = Boolean(elements.debugModeCheckbox?.checked);

    state.confirmStep = 1;
    let text;
    if (debugMode) {
      text = t('confirmStep1Debug');
    } else {
      text = t('confirmStep1', { current: currentSlot, target: targetSlot });
      text += withEfisp ? t('confirmStep1Efisp') : t('confirmStep1NoEfisp');
    }

    elements.confirmText.textContent = text;
    elements.nextConfirmButton.textContent = debugMode ? t('startDebug') : t('nextConfirm');
    elements.confirmModal.classList.remove('hidden');
    elements.confirmModal.setAttribute('aria-hidden', 'false');
  }

  function handleConfirmProgress() {
    const debugMode = Boolean(elements.debugModeCheckbox?.checked);

    if (state.confirmStep === 1 && !debugMode) {
      state.confirmStep = 2;
      elements.confirmText.textContent = t('confirmStep2');
      elements.nextConfirmButton.textContent = t('confirmFlash');
      return;
    }

    closeConfirmModal();
    startFlash();
  }

  function startFlash() {
    const withEfisp = elements.updateEfispCheckbox?.checked;
    const debugMode = elements.debugModeCheckbox?.checked;
    const flashMode = debugMode ? 'debug' : withEfisp ? 'update-efisp' : 'skip-efisp';

    try {
      const output = parseKeyValueOutput(runScript('start', flashMode));
      if (output.ALREADY_RUNNING) toast(t('toasts.alreadyRunning'));
      else if (output.STARTED === '1') toast(debugMode ? t('toasts.debugStarted') : t('toasts.started'));
      else if (output.FINISHED === 'success') toast(debugMode ? t('toasts.finishedDebug') : t('toasts.finishedSuccess'));
      else if (output.FINISHED === 'warning') toast(t('toasts.finishedWarning'));
      else if (output.FINISHED === 'error') toast(t('toasts.finishedError'));
      else toast(t('toasts.startFailed'));
    } catch (error) {
      toast(error.message);
    }

    manualRefresh();
  }

  function clearLog() {
    try {
      const output = parseKeyValueOutput(runScript('clear-log'));
      if (output.BUSY === '1') {
        toast(t('toasts.busyClear'));
        return;
      }
      toast(t('toasts.cleared'));
    } catch (error) {
      toast(error.message);
    }

    manualRefresh();
  }

  // ---- polling ----
  function schedulePoll(ms) {
    clearTimeout(state.pollTimer);
    state.pollTimer = setTimeout(poll, ms);
  }

  function poll() {
    const status = refreshStatus();
    const busy = status?.RUNNING === '1';
    if (busy) refreshLog();
    schedulePoll(busy ? 3000 : 8000);
  }

  function manualRefresh() {
    clearTimeout(state.pollTimer);
    state.prevStatusRaw = '';
    refreshStatus();
    refreshLog();
    schedulePoll(state.status?.RUNNING === '1' ? 3000 : 8000);
  }

  function renderLangLabel() {
    // Show the language the button switches to.
    elements.langLabel.textContent = i18n?.lang === 'zh' ? 'EN' : '中文';
  }

  function toggleLang() {
    if (!i18n) return;
    i18n.setLang(i18n.lang === 'zh' ? 'en' : 'zh');
  }

  function init() {
    if (elements.langButton) elements.langButton.addEventListener('click', toggleLang);
    document.addEventListener('i18n:applied', () => {
      renderLangLabel();
      if (state.status) renderStatus(state.status);
      else if (elements.appTitle) elements.appTitle.textContent = t('title');
      if (!state.initError) refreshLog();
    });

    try {
      const info = moduleInfo();
      state.moduleDir = info.moduleDir;
      state.scriptPath = `${state.moduleDir}/bin/bl_flasher.sh`;
    } catch (error) {
      state.initError = error;
      renderStatusError(error.message);
      elements.logOutput.textContent = error.message;
      renderLangLabel();
      return;
    }

    elements.refreshButton?.addEventListener('click', manualRefresh);
    elements.flashButton?.addEventListener('click', openConfirmModal);
    elements.clearLogButton?.addEventListener('click', clearLog);
    elements.cancelConfirmButton?.addEventListener('click', closeConfirmModal);
    elements.nextConfirmButton?.addEventListener('click', handleConfirmProgress);
    elements.confirmModal?.addEventListener('click', (event) => {
      if (event.target === elements.confirmModal) closeConfirmModal();
    });

    renderLangLabel();
    refreshStatus();
    refreshLog();
    schedulePoll(state.status?.RUNNING === '1' ? 3000 : 8000);
  }

  init();
})();
