const messagesEl = document.getElementById('messages');
const emptyState = document.getElementById('empty-state');
const form = document.getElementById('composer');
const input = document.getElementById('input');
const sendBtn = document.getElementById('send-btn');
const clearBtn = document.getElementById('clear-btn');
const modelBadge = document.getElementById('model-badge');

// Full conversation history sent to the API on each turn.
let history = [];
let streaming = false;

// --- Setup ----------------------------------------------------------------
fetch('/api/config')
  .then((r) => r.json())
  .then((cfg) => {
    modelBadge.textContent = cfg.model || 'grok';
    if (!cfg.configured) {
      addMessage('bot', 'API 키가 설정되지 않았습니다. .env 파일에 XAI_API_KEY를 추가하세요.', true);
    }
  })
  .catch(() => (modelBadge.textContent = 'offline'));

// Auto-grow textarea.
input.addEventListener('input', () => {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 200) + 'px';
});

// Enter to send, Shift+Enter for newline.
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    form.requestSubmit();
  }
});

form.addEventListener('submit', (e) => {
  e.preventDefault();
  send();
});

clearBtn.addEventListener('click', () => {
  history = [];
  messagesEl.querySelectorAll('.msg').forEach((n) => n.remove());
  emptyState.style.display = '';
});

// --- Rendering ------------------------------------------------------------
function addMessage(role, text, isError = false) {
  emptyState.style.display = 'none';

  const wrap = document.createElement('div');
  wrap.className = `msg ${role}`;

  const avatar = document.createElement('div');
  avatar.className = 'avatar';
  avatar.textContent = role === 'user' ? '나' : '✦';

  const bubble = document.createElement('div');
  bubble.className = 'bubble' + (isError ? ' error' : '');
  bubble.textContent = text;

  wrap.append(avatar, bubble);
  messagesEl.appendChild(wrap);
  scrollToBottom();
  return bubble;
}

function scrollToBottom() {
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

function setStreaming(on) {
  streaming = on;
  sendBtn.disabled = on;
  input.disabled = on;
}

// --- Send + stream --------------------------------------------------------
async function send() {
  const text = input.value.trim();
  if (!text || streaming) return;

  input.value = '';
  input.style.height = 'auto';

  addMessage('user', text);
  history.push({ role: 'user', content: text });

  const bubble = addMessage('bot', '');
  const cursor = document.createElement('span');
  cursor.className = 'cursor';
  bubble.appendChild(cursor);

  setStreaming(true);
  let answer = '';

  try {
    const res = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: history }),
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
        const lines = evt.split('\n');
        let eventType = 'message';
        let dataStr = '';
        for (const line of lines) {
          if (line.startsWith('event:')) eventType = line.slice(6).trim();
          else if (line.startsWith('data:')) dataStr += line.slice(5).trim();
        }
        if (!dataStr) continue;

        const data = JSON.parse(dataStr);
        if (eventType === 'error') {
          throw new Error(data.detail ? `${data.error}: ${data.detail}` : data.error);
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
    if (answer) history.push({ role: 'assistant', content: answer });
    else bubble.textContent = '(빈 응답)';
  } catch (err) {
    cursor.remove();
    bubble.classList.add('error');
    bubble.textContent = '⚠ ' + err.message;
    // Roll back the user turn so retry doesn't duplicate context.
    history.pop();
  } finally {
    setStreaming(false);
    input.focus();
  }
}
