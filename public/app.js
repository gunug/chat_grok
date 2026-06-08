// ===========================================================================
//  Grok Chat — frontend logic with localStorage persistence
// ===========================================================================

const STORAGE_KEY = 'grok_chat_v1';

const els = {
  messages: document.getElementById('messages'),
  empty: document.getElementById('empty-state'),
  form: document.getElementById('composer'),
  input: document.getElementById('input'),
  sendBtn: document.getElementById('send-btn'),
  newChat: document.getElementById('new-chat'),
  convList: document.getElementById('conv-list'),
  convTitle: document.getElementById('conv-title'),
  modelBadge: document.getElementById('model-badge'),
  exportMd: document.getElementById('export-md'),
  exportJson: document.getElementById('export-json'),
  toggleSidebar: document.getElementById('toggle-sidebar'),
  sidebar: document.getElementById('sidebar'),
  tokenBadge: document.getElementById('token-badge'),
};

let streaming = false;
let sessionTokens = 0; // 이번 세션(새로고침 전) 누적 total 토큰
let sessionCost = 0; // 이번 세션 누적 비용(USD)

// --- Store -----------------------------------------------------------------
// Shape: { conversations: [{id, title, createdAt, updatedAt, messages:[{role,content}]}], activeId }
const store = {
  data: { conversations: [], activeId: null },

  load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) this.data = JSON.parse(raw);
    } catch {
      this.data = { conversations: [], activeId: null };
    }
    if (!Array.isArray(this.data.conversations)) this.data.conversations = [];
    // 구버전 저장본 호환: usage 필드 없으면 0으로 채움.
    for (const c of this.data.conversations) {
      if (!c.usage) c.usage = { tokens: 0, cost: 0 };
    }
  },

  save() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.data));
    } catch (e) {
      console.warn('저장 실패(용량 초과 가능):', e);
    }
  },

  active() {
    return this.data.conversations.find((c) => c.id === this.data.activeId) || null;
  },

  create() {
    const conv = {
      id: 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      title: '새 대화',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      messages: [],
      usage: { tokens: 0, cost: 0 },
    };
    this.data.conversations.unshift(conv);
    this.data.activeId = conv.id;
    this.save();
    return conv;
  },

  ensureActive() {
    return this.active() || this.create();
  },

  remove(id) {
    this.data.conversations = this.data.conversations.filter((c) => c.id !== id);
    if (this.data.activeId === id) {
      this.data.activeId = this.data.conversations[0]?.id || null;
    }
    this.save();
  },

  touch(conv) {
    conv.updatedAt = Date.now();
    // Auto-title from the first user message.
    if (conv.title === '새 대화') {
      const firstUser = conv.messages.find((m) => m.role === 'user');
      if (firstUser) {
        conv.title = firstUser.content.slice(0, 40).replace(/\s+/g, ' ').trim();
      }
    }
    this.save();
  },
};

// --- Rendering -------------------------------------------------------------
function renderSidebar() {
  els.convList.innerHTML = '';
  for (const conv of store.data.conversations) {
    const li = document.createElement('li');
    li.className = 'conv-item' + (conv.id === store.data.activeId ? ' active' : '');

    const main = document.createElement('div');
    main.className = 'conv-main';

    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = conv.title || '새 대화';
    main.appendChild(name);

    const u = conv.usage || { tokens: 0, cost: 0 };
    if (u.tokens > 0) {
      const usageEl = document.createElement('span');
      usageEl.className = 'conv-usage';
      usageEl.textContent = `${u.tokens.toLocaleString()} tok · $${u.cost.toFixed(4)}`;
      main.appendChild(usageEl);
    }

    const del = document.createElement('button');
    del.className = 'del';
    del.textContent = '🗑';
    del.title = '삭제';
    del.addEventListener('click', (e) => {
      e.stopPropagation();
      if (confirm('이 대화를 삭제할까요?')) {
        store.remove(conv.id);
        renderAll();
      }
    });

    li.append(main, del);
    li.addEventListener('click', () => {
      store.data.activeId = conv.id;
      store.save();
      renderAll();
    });
    els.convList.appendChild(li);
  }
}

function renderMessages() {
  // Clear current message nodes (keep the empty-state element).
  els.messages.querySelectorAll('.msg').forEach((n) => n.remove());
  const conv = store.active();
  els.convTitle.textContent = conv?.title || 'Grok Chat';

  if (!conv || conv.messages.length === 0) {
    els.empty.style.display = '';
    return;
  }
  els.empty.style.display = 'none';
  for (const m of conv.messages) addBubble(m.role, m.content);
  scrollToBottom();
}

function renderAll() {
  renderSidebar();
  renderMessages();
}

function addBubble(role, text, isError = false) {
  els.empty.style.display = 'none';
  const uiRole = role === 'assistant' ? 'bot' : role;

  const wrap = document.createElement('div');
  wrap.className = `msg ${uiRole}`;

  const avatar = document.createElement('div');
  avatar.className = 'avatar';
  avatar.textContent = uiRole === 'user' ? '나' : '✦';

  const bubble = document.createElement('div');
  bubble.className = 'bubble' + (isError ? ' error' : '');
  bubble.textContent = text;

  wrap.append(avatar, bubble);
  els.messages.appendChild(wrap);
  return bubble;
}

function scrollToBottom() {
  els.messages.scrollTop = els.messages.scrollHeight;
}

// 봇 답변 아래에 이번 응답의 토큰 사용량 + 비용을 표시하고 세션 누적치를 갱신.
function showUsage(bubble, u) {
  const line = document.createElement('div');
  line.className = 'usage-line';
  const parts = [
    `입력 ${u.prompt}` + (u.cached ? ` (캐시 ${u.cached})` : ''),
    `출력 ${u.completion}` + (u.reasoning ? ` (추론 ${u.reasoning})` : ''),
    `합계 ${u.total} tok`,
  ];
  if (u.costUsd != null) parts.push(`💵 $${u.costUsd.toFixed(6)}`);
  line.textContent = '🔢 ' + parts.join(' · ');
  bubble.appendChild(line);

  sessionTokens += u.total || 0;
  sessionCost += u.costUsd || 0;
  els.tokenBadge.textContent =
    `∑ ${sessionTokens.toLocaleString()} tok` +
    (sessionCost > 0 ? ` · $${sessionCost.toFixed(4)}` : '');
}

function setStreaming(on) {
  streaming = on;
  els.sendBtn.disabled = on;
  els.input.disabled = on;
}

// --- Send + stream ---------------------------------------------------------
async function send() {
  const text = els.input.value.trim();
  if (!text || streaming) return;

  els.input.value = '';
  els.input.style.height = 'auto';

  const conv = store.ensureActive();
  conv.messages.push({ role: 'user', content: text });
  store.touch(conv);
  renderSidebar();
  addBubble('user', text);
  scrollToBottom();

  const bubble = addBubble('bot', '');
  const cursor = document.createElement('span');
  cursor.className = 'cursor';
  bubble.appendChild(cursor);

  setStreaming(true);
  let answer = '';
  let usage = null;

  try {
    const res = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: conv.messages }),
    });

    if (!res.ok || !res.body) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || `요청 실패 (${res.status})`);
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      const events = buffer.split('\n\n');
      buffer = events.pop() ?? '';

      for (const evt of events) {
        let eventType = 'message';
        let dataStr = '';
        for (const line of evt.split('\n')) {
          if (line.startsWith('event:')) eventType = line.slice(6).trim();
          else if (line.startsWith('data:')) dataStr += line.slice(5).trim();
        }
        if (!dataStr) continue;

        const data = JSON.parse(dataStr);
        if (eventType === 'error') {
          throw new Error(data.detail ? `${data.error}: ${data.detail}` : data.error);
        }
        if (eventType === 'usage') {
          usage = data;
          continue;
        }
        if (eventType === 'done') continue;
        if (data.delta) {
          answer += data.delta;
          cursor.remove();
          bubble.textContent = answer;
          bubble.appendChild(cursor);
          scrollToBottom();
        }
      }
    }

    cursor.remove();
    if (answer) {
      bubble.textContent = answer;
      conv.messages.push({ role: 'assistant', content: answer });
      if (usage) {
        showUsage(bubble, usage);
        if (!conv.usage) conv.usage = { tokens: 0, cost: 0 };
        conv.usage.tokens += usage.total || 0;
        conv.usage.cost += usage.costUsd || 0;
      }
      store.touch(conv);
      renderSidebar(); // 대화별 누적 사용량 갱신
    } else {
      bubble.textContent = '(빈 응답)';
    }
  } catch (err) {
    cursor.remove();
    bubble.classList.add('error');
    bubble.textContent = '⚠ ' + err.message;
    // Roll back the user turn so a retry doesn't duplicate context.
    conv.messages.pop();
    store.touch(conv);
    renderSidebar();
  } finally {
    setStreaming(false);
    els.input.focus();
  }
}

// --- Export ----------------------------------------------------------------
function download(filename, text, mime) {
  const blob = new Blob([text], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function safeName(s) {
  return (s || 'chat').replace(/[\\/:*?"<>|]+/g, '_').slice(0, 50);
}

function exportMarkdown() {
  const conv = store.active();
  if (!conv || conv.messages.length === 0) return alert('내보낼 대화가 없습니다.');
  const lines = [`# ${conv.title}`, '', `_${new Date(conv.createdAt).toLocaleString()}_`, ''];
  for (const m of conv.messages) {
    lines.push(m.role === 'user' ? '**🧑 나**' : '**✦ Grok**', '', m.content, '', '---', '');
  }
  download(`${safeName(conv.title)}.md`, lines.join('\n'), 'text/markdown');
}

function exportJSON() {
  const conv = store.active();
  if (!conv || conv.messages.length === 0) return alert('내보낼 대화가 없습니다.');
  download(`${safeName(conv.title)}.json`, JSON.stringify(conv, null, 2), 'application/json');
}

// --- Wiring ----------------------------------------------------------------
els.input.addEventListener('input', () => {
  els.input.style.height = 'auto';
  els.input.style.height = Math.min(els.input.scrollHeight, 200) + 'px';
});
els.input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    els.form.requestSubmit();
  }
});
els.form.addEventListener('submit', (e) => {
  e.preventDefault();
  send();
});
els.newChat.addEventListener('click', () => {
  store.create();
  renderAll();
  els.input.focus();
});
els.exportMd.addEventListener('click', exportMarkdown);
els.exportJson.addEventListener('click', exportJSON);
els.toggleSidebar.addEventListener('click', () => {
  els.sidebar.classList.toggle('collapsed');
});

// --- Init ------------------------------------------------------------------
fetch('/api/config')
  .then((r) => r.json())
  .then((cfg) => {
    els.modelBadge.textContent = cfg.model || 'grok';
    if (!cfg.configured) {
      addBubble('bot', 'API 키가 설정되지 않았습니다. .env 파일에 XAI_API_KEY를 추가하세요.', true);
    }
  })
  .catch(() => (els.modelBadge.textContent = 'offline'));

store.load();
renderAll();
els.input.focus();
