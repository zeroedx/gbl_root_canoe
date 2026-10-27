(() => {
  'use strict';
  const STORE_KEY = 'blFlasherLang';
  const supported = ['zh', 'en'];

  function detect() {
    try {
      const saved = localStorage.getItem(STORE_KEY);
      if (supported.includes(saved)) return saved;
    } catch {}
    const preferred = (navigator.languages && navigator.languages[0]) || navigator.language || 'en';
    return /^zh(?:[-_]|$)/i.test(preferred) ? 'zh' : 'en';
  }

  const messages = {
    zh: {
      title: '假回锁',
      subtitle: 'BL Flasher',
      refresh: '刷新状态',
      language: '切换语言',
      statusHeading: '模块状态',
      loading: '正在读取模块状态…',
      deviceHeading: '设备信息',
      device: '设备代号',
      model: '机型',
      currentSlot: '当前槽位',
      targetSlot: '目标槽位',
      version: '模块版本',
      unknown: '未知',
      actionsHeading: '操作',
      flash: '刷写到另一槽位',
      updateEfisp: '同时更新 efisp（默认关闭）',
      debugMode: '调试模式（仅处理不刷写）',
      clearLog: '清空日志',
      dangerNote: '刷写对象为 bootloader 相关分区，风险较高。开始前请确认镜像与机型严格匹配。',
      logHeading: '执行日志',
      logEmpty: '暂无日志输出',
      logHint: '自动读取最近 200 行',
      aboutHeading: '说明',
      aboutDevices: '支持设备：myron、pudding、popsicle、pandora、nezha、nezha_global。未知设备不会映射到其他机型。',
      aboutPrereq: '使用前提：内核无 Baseband Guard，设备 BL 锁已解锁，机型为 8gen5 / 8elitegen5。',
      aboutSafety: '本页面只调用模块自身的刷写脚本。写入前一律校验固件 SHA-256；校验失败或无法确认时一律判定为失败，不会默认放行。',
      stateIdle: '空闲',
      stateRunning: '正在执行',
      stateWaiting: '需要你处理',
      stateSuccess: '操作成功',
      stateFailed: '操作失败',
      stateUnknown: '状态未知',
      stateUnreachable: '无法读取状态',
      slotLine: '当前 {current} → 目标 {target}',
      slotUnknown: '槽位未知',
      rebootHint: '补丁已写入，请重启设备使其生效。',
      staleHint: '上次任务未正常结束（页面关闭或设备重启），结果无法确认。',
      updatedAt: '更新于 {time}',
      never: '尚未执行',
      confirmTitle: '确认刷写',
      confirmStep1: '第一次确认：将把当前槽位（{current}）的 BL 分区拷贝到槽位 {target}。',
      confirmStep1Efisp: '，并更新 efisp。',
      confirmStep1NoEfisp: '，不更新 efisp。',
      confirmStep1Debug: '调试模式：将执行全部处理流程但不刷写分区，生成的文件保存在模块 tmp 目录。',
      confirmStep2: '第二次确认：这是高风险写入操作，错误操作可能导致目标槽位无法启动。确认后将立即开始刷写。',
      nextConfirm: '继续确认',
      confirmFlash: '确认刷写',
      startDebug: '开始调试',
      cancel: '取消',
      toasts: {
        alreadyRunning: '已有刷写任务在运行',
        started: '刷写任务已启动',
        debugStarted: '调试任务已启动',
        finishedSuccess: '刷写已完成',
        finishedDebug: '调试完成',
        finishedWarning: 'BL 刷写完成，但 efisp 未更新',
        finishedError: '任务已结束（失败）',
        startFailed: '任务启动失败',
        busyClear: '任务运行中，暂时不能清空日志',
        cleared: '日志已清空',
        initFailed: 'WebUI 初始化失败',
        notInWebui: '请从模块管理器的 WebUI 打开此面板',
        execUnavailable: '模块管理器的 exec 接口不可用',
      },
    },
    en: {
      title: 'Fake BL EFISP',
      subtitle: 'BL Flasher',
      refresh: 'Refresh status',
      language: 'Switch language',
      statusHeading: 'Module status',
      loading: 'Reading module status…',
      deviceHeading: 'Device',
      device: 'Codename',
      model: 'Model',
      currentSlot: 'Current slot',
      targetSlot: 'Target slot',
      version: 'Module version',
      unknown: 'Unknown',
      actionsHeading: 'Actions',
      flash: 'Flash to the other slot',
      updateEfisp: 'Also update efisp (off by default)',
      debugMode: 'Debug mode (process only, no flash)',
      clearLog: 'Clear log',
      dangerNote: 'The target is a bootloader partition; this is high risk. Make sure the image matches your exact model before starting.',
      logHeading: 'Log',
      logEmpty: 'No log output yet',
      logHint: 'Shows the last 200 lines',
      aboutHeading: 'About',
      aboutDevices: 'Supported devices: myron, pudding, popsicle, pandora, nezha, nezha_global. An unknown device is never mapped to another model.',
      aboutPrereq: 'Requirements: no Baseband Guard in the kernel, unlocked bootloader, 8gen5 / 8elitegen5 SoC.',
      aboutSafety: 'This page only calls the module’s own flashing script. Firmware is always verified by SHA-256 first; a failed or unverifiable check is treated as failure and never allowed through.',
      stateIdle: 'Idle',
      stateRunning: 'Running',
      stateWaiting: 'Action needed',
      stateSuccess: 'Success',
      stateFailed: 'Failed',
      stateUnknown: 'Unknown state',
      stateUnreachable: 'Status unavailable',
      slotLine: 'Current {current} → target {target}',
      slotUnknown: 'Slot unknown',
      rebootHint: 'The patch is written. Reboot the device to apply it.',
      staleHint: 'The previous task did not finish normally (the page was closed or the device rebooted); its result cannot be confirmed.',
      updatedAt: 'Updated {time}',
      never: 'Never run',
      confirmTitle: 'Confirm flash',
      confirmStep1: 'First confirmation: the BL partition of the current slot ({current}) will be copied to slot {target}.',
      confirmStep1Efisp: ' efisp will be updated too.',
      confirmStep1NoEfisp: ' efisp will not be updated.',
      confirmStep1Debug: 'Debug mode: the full pipeline runs but nothing is written; the generated files stay in the module tmp directory.',
      confirmStep2: 'Second confirmation: this writes to a bootloader partition and a mistake can leave the target slot unbootable. Flashing starts as soon as you confirm.',
      nextConfirm: 'Continue',
      confirmFlash: 'Flash now',
      startDebug: 'Start debug',
      cancel: 'Cancel',
      toasts: {
        alreadyRunning: 'A flash task is already running',
        started: 'Flash task started',
        debugStarted: 'Debug task started',
        finishedSuccess: 'Flash completed',
        finishedDebug: 'Debug completed',
        finishedWarning: 'BL flashed, but efisp was not updated',
        finishedError: 'Task finished (failed)',
        startFailed: 'Could not start the task',
        busyClear: 'A task is running; the log cannot be cleared yet',
        cleared: 'Log cleared',
        initFailed: 'WebUI initialisation failed',
        notInWebui: 'Open this panel from your module manager’s WebUI',
        execUnavailable: 'The module manager exec interface is unavailable',
      },
    },
  };

  let lang = detect();

  const t = (key, values = {}) => {
    const table = messages[lang] || messages.en;
    let node = table;
    for (const part of key.split('.')) node = node?.[part];
    if (node == null) return key;
    return String(node).replace(/\{(\w+)\}/g, (match, name) =>
      values[name] != null ? values[name] : match,
    );
  };

  function apply() {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = t('title');
    document.querySelectorAll('[data-i18n]').forEach((node) => {
      node.textContent = t(node.dataset.i18n);
    });
    for (const attribute of ['aria-label', 'title', 'placeholder']) {
      document.querySelectorAll('[data-i18n-' + attribute + ']').forEach((node) => {
        node.setAttribute(attribute, t(node.getAttribute('data-i18n-' + attribute)));
      });
    }
    document.dispatchEvent(new CustomEvent('i18n:applied', { detail: { lang } }));
  }

  window.BlFlasherI18n = {
    t,
    apply,
    get lang() {
      return lang;
    },
    setLang(next) {
      if (!supported.includes(next) || next === lang) return;
      lang = next;
      try {
        localStorage.setItem(STORE_KEY, lang);
      } catch {}
      apply();
    },
  };
  apply();
})();
