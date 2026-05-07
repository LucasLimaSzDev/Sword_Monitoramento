(function () {
  const state = {
    view: "dashboard",
    loading: true,
    error: "",
    toast: "",
    auth: {
      checked: false,
      setupRequired: false,
      user: null,
      roles: []
    },
    summary: null,
    devices: [],
    events: [],
    alerts: [],
    users: [],
    filters: {
      search: "",
      status: "all",
      type: "all",
      criticality: "all"
    },
    historyFilters: {
      device: "all",
      status: "all",
      criticality: "all"
    },
    modal: null,
    userModal: null
  };

  const app = document.getElementById("app");
  const api = {
    get: (url) => request(url),
    post: (url, body) => request(url, { method: "POST", body }),
    put: (url, body) => request(url, { method: "PUT", body }),
    delete: (url) => request(url, { method: "DELETE" })
  };

  function request(url, options = {}) {
    const init = {
      method: options.method || "GET",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin"
    };

    if (options.body) {
      init.body = JSON.stringify(options.body);
    }

    return fetch(url, init).then(async (response) => {
      const text = await response.text();
      let data = null;
      if (text) {
        try {
          data = JSON.parse(text);
        } catch (error) {
          data = { error: "Resposta invalida do servidor." };
        }
      }
      if (!response.ok) {
        if (response.status === 401) {
          state.auth.user = null;
          state.auth.setupRequired = false;
          state.loading = false;
          state.error = "";
          render();
        }
        throw new Error((data && data.error) || "Falha na requisicao.");
      }
      return data;
    });
  }

  function canOperate() {
    return state.auth.user && ["admin", "operator"].includes(state.auth.user.role);
  }

  function isAdmin() {
    return state.auth.user && state.auth.user.role === "admin";
  }

  function roleLabel(role) {
    const map = {
      admin: "Administrador",
      operator: "Operador",
      viewer: "Visualizador"
    };
    return map[role] || role || "-";
  }

  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }

  function asSummary(value) {
    return {
      total: Number(value?.total || 0),
      online: Number(value?.online || 0),
      offline: Number(value?.offline || 0),
      critical_offline: Number(value?.critical_offline || 0),
      open_alerts: Number(value?.open_alerts || 0),
      generated_at: value?.generated_at || new Date().toISOString()
    };
  }

  function formatDate(value) {
    if (!value) return "-";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "-";
    return date.toLocaleString("pt-BR", {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    });
  }

  function timeAgo(value) {
    if (!value) return "-";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "-";
    const seconds = Math.max(0, Math.floor((Date.now() - date.getTime()) / 1000));
    if (seconds < 60) return `ha ${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `ha ${minutes} min`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `ha ${hours} h`;
    const days = Math.floor(hours / 24);
    return `ha ${days} d`;
  }

  function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || seconds === "") return "-";
    const total = Number(seconds);
    if (!Number.isFinite(total)) return "-";
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const parts = [];
    if (h) parts.push(`${h}h`);
    if (m) parts.push(`${m}min`);
    parts.push(`${s}s`);
    return parts.join(" ");
  }

  function labelCriticality(value) {
    const map = {
      baixa: "Baixa",
      media: "Media",
      alta: "Alta",
      critica: "Critica"
    };
    return map[value] || value || "-";
  }

  function criticalityClass(value) {
    return {
      baixa: "low",
      media: "medium",
      alta: "high",
      critica: "critical"
    }[value] || "inactive";
  }

  function deviceById(id) {
    return asArray(state.devices).find((device) => device.id === id) || null;
  }

  function filteredDevices() {
    const search = state.filters.search.trim().toLowerCase();
    return asArray(state.devices).filter((device) => {
      const matchesSearch = !search || [device.name, device.host, device.type, device.location]
        .join(" ")
        .toLowerCase()
        .includes(search);
      const matchesStatus = state.filters.status === "all" || device.current_status === state.filters.status;
      const matchesType = state.filters.type === "all" || device.type === state.filters.type;
      const matchesCriticality = state.filters.criticality === "all" || device.criticality === state.filters.criticality;
      return matchesSearch && matchesStatus && matchesType && matchesCriticality;
    });
  }

  function filteredEvents() {
    return asArray(state.events)
      .map((event) => ({ ...event, device: deviceById(event.device_id) }))
      .filter((event) => {
        const deviceMatch = state.historyFilters.device === "all" || event.device_id === state.historyFilters.device;
        const statusMatch = state.historyFilters.status === "all" || event.status === state.historyFilters.status;
        const criticalityMatch = state.historyFilters.criticality === "all" || event.criticality === state.historyFilters.criticality;
        return deviceMatch && statusMatch && criticalityMatch;
      })
      .sort((a, b) => new Date(b.down_at || 0) - new Date(a.down_at || 0));
  }

  function openAlerts() {
    return asArray(state.alerts)
      .filter((alert) => alert.status === "open")
      .map((alert) => ({ ...alert, device: deviceById(alert.device_id) }))
      .filter((alert) => alert.device)
      .sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
  }

  function options(values, selected, labelAll) {
    return [`<option value="all"${selected === "all" ? " selected" : ""}>${labelAll}</option>`]
      .concat(values.map((value) => `<option value="${escapeHtml(value)}"${selected === value ? " selected" : ""}>${escapeHtml(value)}</option>`))
      .join("");
  }

  function deviceOptions(selected, labelAll) {
    return [`<option value="all"${selected === "all" ? " selected" : ""}>${labelAll}</option>`]
      .concat(asArray(state.devices).map((device) => `
        <option value="${escapeHtml(device.id)}"${selected === device.id ? " selected" : ""}>${escapeHtml(device.name)}</option>
      `))
      .join("");
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  async function loadData({ silent = false } = {}) {
    if (!state.auth.user) {
      state.loading = false;
      render();
      return;
    }

    if (!silent) {
      state.loading = true;
      state.error = "";
      render();
    }

    try {
      const [summary, devices, events, alerts] = await Promise.all([
        api.get("/api/summary"),
        api.get("/api/devices"),
        api.get("/api/events"),
        api.get("/api/alerts")
      ]);
      state.summary = asSummary(summary);
      state.devices = asArray(devices);
      state.events = asArray(events);
      state.alerts = asArray(alerts);
      state.error = "";
    } catch (error) {
      state.error = error.message;
    } finally {
      state.loading = false;
      render();
    }
  }

  function setToast(message) {
    state.toast = message;
    render();
    window.clearTimeout(setToast.timer);
    setToast.timer = window.setTimeout(() => {
      state.toast = "";
      render();
    }, 2600);
  }

  async function loadAuthStatus() {
    try {
      const status = await api.get("/api/auth/status");
      state.auth.checked = true;
      state.auth.setupRequired = Boolean(status?.setup_required);
      state.auth.user = status?.authenticated ? status.user : null;
      state.auth.roles = asArray(status?.roles);
      if (state.auth.user) {
        await loadData({ silent: true });
      } else {
        state.loading = false;
        render();
      }
    } catch (error) {
      state.auth.checked = true;
      state.loading = false;
      state.error = error.message;
      render();
    }
  }

  async function loadUsers() {
    if (!isAdmin()) {
      state.users = [];
      return;
    }

    state.users = asArray(await api.get("/api/users"));
  }

  function pageTitle() {
    const map = {
      dashboard: ["Dashboard", "Visao geral da infraestrutura"],
      devices: ["Dispositivos", "Cadastro e operacao dos ativos monitorados"],
      alerts: ["Alertas", "Ocorrencias criticas em aberto"],
      history: ["Historico", "Eventos de disponibilidade e indisponibilidade"],
      users: ["Usuarios", "Controle de acesso e cargos"]
    };
    return map[state.view] || map.dashboard;
  }

  function render() {
    try {
      if (!state.auth.checked) {
        app.innerHTML = `<div class="fatal-screen"><section class="panel">Carregando seguranca...</section></div>`;
        return;
      }

      if (state.auth.setupRequired) {
        app.innerHTML = renderSetupScreen();
        bindAuthEvents();
        return;
      }

      if (!state.auth.user) {
        app.innerHTML = renderLoginScreen();
        bindAuthEvents();
        return;
      }

      const [title, subtitle] = pageTitle();
      app.innerHTML = `
        <div class="app-shell">
          ${renderSidebar()}
          <main class="main">
            <header class="topbar">
              <div>
                <h1 class="page-title">${title}</h1>
                <div class="page-subtitle">${subtitle}</div>
              </div>
              <div class="top-actions">
                <div class="live-pill"><span class="live-dot"></span>Monitoramento ativo</div>
                <div class="timestamp">Atualizado: ${state.summary ? timeAgo(state.summary.generated_at) : "-"}</div>
                ${canOperate() ? `<button class="button" data-action="run-monitor">Verificar agora</button>` : ""}
                <div class="user-chip">
                  <div class="avatar">${escapeHtml(getInitials(state.auth.user.name))}</div>
                  <div>
                    <strong>${escapeHtml(state.auth.user.name)}</strong>
                    <div class="mini-text">${roleLabel(state.auth.user.role)}</div>
                  </div>
                </div>
                <button class="button" data-action="logout">Sair</button>
              </div>
            </header>
            <section class="content">
              ${state.loading ? `<div class="panel loading-panel">Carregando interface...</div>` : ""}
              ${state.error ? `<div class="panel error-panel"><strong>Erro:</strong> ${escapeHtml(state.error)} <button class="button" data-action="reload">Tentar novamente</button></div>` : ""}
              ${!state.loading && !state.error ? renderView() : ""}
            </section>
          </main>
          ${state.modal ? renderModal() : ""}
          ${state.userModal ? renderUserModal() : ""}
          ${state.toast ? `<div class="toast">${escapeHtml(state.toast)}</div>` : ""}
        </div>
      `;

      bindEvents();
    } catch (error) {
      state.loading = false;
      app.innerHTML = `
        <div class="fatal-screen">
          <section class="panel">
            <h1 class="page-title">Falha ao renderizar a interface</h1>
            <p>${escapeHtml(error.message)}</p>
            <button class="button primary" id="fatal-reload">Recarregar dados</button>
          </section>
        </div>
      `;
      const button = document.getElementById("fatal-reload");
      if (button) button.addEventListener("click", () => loadData());
    }
  }

  function getInitials(name) {
    return String(name || "U")
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((part) => part[0] || "")
      .join("")
      .toUpperCase() || "U";
  }

  function renderAuthShell(title, subtitle, formHtml) {
    return `
      <div class="auth-screen">
        <section class="auth-panel">
          <div class="auth-brand">
            <div class="brand-mark">MI</div>
            <div>
              <div class="brand-title">Monitoramento</div>
              <div class="brand-subtitle">Acesso seguro ao painel</div>
            </div>
          </div>
          <h1>${title}</h1>
          <p>${subtitle}</p>
          ${state.error ? `<div class="auth-error">${escapeHtml(state.error)}</div>` : ""}
          ${formHtml}
        </section>
      </div>
    `;
  }

  function renderSetupScreen() {
    return renderAuthShell(
      "Criar administrador",
      "Configure o primeiro usuario com permissao total para iniciar a versao 2.0.",
      `
        <form class="auth-form" id="setup-form">
          <label>Nome<input class="input" name="name" required autocomplete="name"></label>
          <label>Email<input class="input" name="email" required type="email" autocomplete="email"></label>
          <label>Senha<input class="input" name="password" required type="password" minlength="8" autocomplete="new-password"></label>
          <button class="button primary" type="submit">Criar administrador</button>
        </form>
      `
    );
  }

  function renderLoginScreen() {
    return renderAuthShell(
      "Entrar no sistema",
      "Use seu usuario para acessar o dashboard, alertas e historico.",
      `
        <form class="auth-form" id="login-form">
          <label>Email<input class="input" name="email" required type="email" autocomplete="email"></label>
          <label>Senha<input class="input" name="password" required type="password" autocomplete="current-password"></label>
          <button class="button primary" type="submit">Entrar</button>
        </form>
      `
    );
  }

  function bindAuthEvents() {
    const setupForm = document.getElementById("setup-form");
    if (setupForm) setupForm.addEventListener("submit", handleSetupSubmit);

    const loginForm = document.getElementById("login-form");
    if (loginForm) loginForm.addEventListener("submit", handleLoginSubmit);
  }

  function renderSidebar() {
    const count = openAlerts().length;
    const items = [
      ["dashboard", "DB", "Dashboard"],
      ["devices", "DV", "Dispositivos"],
      ["alerts", "AL", "Alertas"],
      ["history", "EV", "Historico"]
    ];
    if (isAdmin()) {
      items.push(["users", "US", "Usuarios"]);
    }

    return `
      <aside class="sidebar">
        <div class="brand">
          <div class="brand-mark">MI</div>
          <div>
            <div class="brand-title">Monitoramento</div>
            <div class="brand-subtitle">Infraestrutura operacional</div>
          </div>
        </div>
        <nav class="nav">
          ${items.map(([view, icon, label]) => `
            <button class="nav-button ${state.view === view ? "active" : ""}" data-view="${view}">
              <span class="nav-icon">${icon}</span>
              <span class="nav-label">${label}</span>
              ${view === "alerts" && count ? `<span class="nav-badge">${count}</span>` : ""}
            </button>
          `).join("")}
        </nav>
        <div class="sidebar-spacer"></div>
        <div class="sidebar-info">
          <div class="mini-panel">
            <div class="mini-title">Sessao segura</div>
            <div class="mini-text">${escapeHtml(state.auth.user.email)}</div>
          </div>
          <div class="mini-panel">
            <div class="mini-title">Base de dados</div>
            <div class="mini-text">data/store.json</div>
          </div>
        </div>
      </aside>
    `;
  }

  function renderView() {
    if (state.view === "devices") return renderDevicesPage();
    if (state.view === "alerts") return renderAlertsPage();
    if (state.view === "history") return renderHistoryPage();
    if (state.view === "users") return renderUsersPage();
    return renderDashboard();
  }

  function renderMetrics() {
    const summary = state.summary || { total: 0, online: 0, offline: 0, critical_offline: 0 };
    const onlinePercent = summary.total ? Math.round((summary.online / summary.total) * 100) : 0;
    const offlinePercent = summary.total ? Math.round((summary.offline / summary.total) * 100) : 0;

    return `
      <div class="metric-grid">
        <article class="metric-card">
          <div class="metric-icon">ALL</div>
          <div>
            <div class="metric-label">Total de dispositivos</div>
            <div class="metric-value">${summary.total}</div>
            <div class="metric-help">Dispositivos ativos monitorados</div>
          </div>
        </article>
        <article class="metric-card">
          <div class="metric-icon green">ON</div>
          <div>
            <div class="metric-label">Online</div>
            <div class="metric-value">${summary.online}</div>
            <div class="metric-help">${onlinePercent}% do total</div>
          </div>
        </article>
        <article class="metric-card">
          <div class="metric-icon red">OFF</div>
          <div>
            <div class="metric-label">Offline</div>
            <div class="metric-value">${summary.offline}</div>
            <div class="metric-help">${offlinePercent}% do total</div>
          </div>
        </article>
        <article class="metric-card">
          <div class="metric-icon amber">!</div>
          <div>
            <div class="metric-label">Criticos offline</div>
            <div class="metric-value">${summary.critical_offline}</div>
            <div class="metric-help">Requer atencao imediata</div>
          </div>
        </article>
      </div>
    `;
  }

  function renderDashboard() {
    if (asArray(state.devices).length === 0) {
      return `
        ${renderMetrics()}
        ${renderEmptyOnboarding()}
      `;
    }

    return `
      ${renderMetrics()}
      <div class="dashboard-grid">
        <div class="stack">
          ${renderDevicesTable({ dashboard: true })}
          ${renderTimeline()}
        </div>
        <div class="stack">
          ${renderCriticalAlerts()}
          ${renderStatusDonut()}
          ${renderRecentEvents()}
        </div>
      </div>
    `;
  }

  function renderEmptyOnboarding() {
    return `
      <section class="panel empty-onboarding">
        <div>
          <div class="empty-kicker">Base limpa</div>
          <h2>Nenhum dispositivo cadastrado</h2>
          <p>Cadastre os ativos reais da rede para iniciar as verificacoes de disponibilidade.</p>
        </div>
        <div class="empty-actions">
          ${canOperate() ? `<button class="button primary" data-action="new-device">Cadastrar dispositivo</button>` : ""}
          <button class="button" data-view="devices">Abrir cadastro</button>
        </div>
      </section>
    `;
  }

  function renderDevicesPage() {
    return `
      ${renderMetrics()}
      ${renderDevicesTable({ dashboard: false })}
    `;
  }

  function renderFilters() {
    const types = [...new Set(asArray(state.devices).map((device) => device.type).filter(Boolean))].sort();
    return `
      <div class="filters">
        <input class="input" data-filter="search" placeholder="Buscar dispositivo..." value="${escapeHtml(state.filters.search)}">
        <select class="select" data-filter="status">
          <option value="all"${state.filters.status === "all" ? " selected" : ""}>Todos os status</option>
          <option value="online"${state.filters.status === "online" ? " selected" : ""}>Online</option>
          <option value="offline"${state.filters.status === "offline" ? " selected" : ""}>Offline</option>
        </select>
        <select class="select" data-filter="type">${options(types, state.filters.type, "Todos os tipos")}</select>
        <select class="select" data-filter="criticality">
          <option value="all"${state.filters.criticality === "all" ? " selected" : ""}>Todas as criticidades</option>
          <option value="baixa"${state.filters.criticality === "baixa" ? " selected" : ""}>Baixa</option>
          <option value="media"${state.filters.criticality === "media" ? " selected" : ""}>Media</option>
          <option value="alta"${state.filters.criticality === "alta" ? " selected" : ""}>Alta</option>
          <option value="critica"${state.filters.criticality === "critica" ? " selected" : ""}>Critica</option>
        </select>
        ${canOperate() ? `<button class="button primary" data-action="new-device">Novo dispositivo</button>` : ""}
      </div>
    `;
  }

  function renderDevicesTable({ dashboard }) {
    const devices = filteredDevices();
    const visible = dashboard ? devices.slice(0, 8) : devices;
    const hasAnyDevice = asArray(state.devices).length > 0;
    const emptyText = hasAnyDevice ? "Nenhum dispositivo encontrado para os filtros atuais." : "Nenhum dispositivo cadastrado.";

    return `
      <section class="table-panel">
        <div class="section-header" style="padding: 18px 18px 0;">
          <h2 class="section-title">Dispositivos monitorados</h2>
          ${renderFilters()}
        </div>
        <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Nome</th>
                <th>IP/Host</th>
                <th>Tipo</th>
                <th>Localizacao</th>
                <th>Criticidade</th>
                <th>Ultima verificacao</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              ${visible.map(renderDeviceRow).join("") || `<tr><td colspan="8"><div class="empty-state">${emptyText}${canOperate() ? `<br><button class="button primary" data-action="new-device">Cadastrar dispositivo</button>` : ""}</div></td></tr>`}
            </tbody>
          </table>
        </div>
        <div class="mini-text" style="padding: 0 18px 18px;">Exibindo ${visible.length} de ${devices.length} dispositivo(s)</div>
      </section>
    `;
  }

  function renderDeviceRow(device) {
    const status = device.is_active ? device.current_status : "inactive";
    const lastCheck = device.last_check_at ? timeAgo(device.last_check_at) : "Nunca verificado";
    return `
      <tr>
        <td>
          <div class="device-name">
            <span class="status-dot ${device.current_status}"></span>
            ${escapeHtml(device.name)}
          </div>
        </td>
        <td>${escapeHtml(device.host)}</td>
        <td>${escapeHtml(device.type)}</td>
        <td>${escapeHtml(device.location)}</td>
        <td><span class="badge ${criticalityClass(device.criticality)}">${labelCriticality(device.criticality)}</span></td>
        <td>${lastCheck}</td>
        <td><span class="badge ${status}">${status === "inactive" ? "INATIVO" : device.current_status.toUpperCase()}</span></td>
        <td>
          ${canOperate() ? `
            <div class="row-actions">
              <button class="button compact" title="Verificar agora" data-action="check-device" data-id="${device.id}">Verificar</button>
              <button class="button compact" title="Editar" data-action="edit-device" data-id="${device.id}">Editar</button>
              <button class="button compact danger" title="Remover" data-action="delete-device" data-id="${device.id}">Excluir</button>
            </div>
          ` : ""}
        </td>
      </tr>
    `;
  }

  function renderCriticalAlerts() {
    const alerts = openAlerts().slice(0, 6);
    return `
      <section class="panel">
        <div class="section-header">
          <h2 class="section-title">Alertas criticos</h2>
          <button class="button" data-view="alerts">Ver todos (${openAlerts().length})</button>
        </div>
        <div class="alert-list">
          ${alerts.map(renderAlertItem).join("") || `<div class="empty-state">Nenhum alerta critico aberto.</div>`}
        </div>
      </section>
    `;
  }

  function renderAlertItem(alert) {
    const device = alert.device || {};
    const priorityClass = alert.priority === "high" ? "high" : "";
    return `
      <article class="alert-item ${priorityClass}">
        <span class="status-dot offline"></span>
        <div>
          <div class="alert-title">${escapeHtml(alert.title)}</div>
          <div class="alert-meta">${escapeHtml(device.location || "-")} - ${escapeHtml(device.host || "-")} - ${timeAgo(alert.created_at)}</div>
        </div>
        ${canOperate() ? `<button class="button" data-action="resolve-alert" data-id="${alert.id}">Resolver</button>` : ""}
      </article>
    `;
  }

  function renderStatusDonut() {
    const summary = state.summary || { total: 0, online: 0, offline: 0, critical_offline: 0 };
    const total = Math.max(1, summary.total);
    const onlineDeg = (summary.online / total) * 360;
    const offlineDeg = onlineDeg + (summary.offline / total) * 360;
    const attention = Math.max(0, summary.critical_offline);
    const donutClass = summary.total === 0 ? "donut empty" : "donut";

    return `
      <section class="panel">
        <h2 class="section-title">Status geral dos dispositivos</h2>
        <div class="donut-wrap" style="margin-top: 16px;">
          <div class="${donutClass}" style="--online:${onlineDeg}deg;--offline:${offlineDeg}deg;"></div>
          <div class="legend">
            <div class="legend-row"><span class="status-dot online"></span><span>Online</span><strong>${summary.online}</strong></div>
            <div class="legend-row"><span class="status-dot offline"></span><span>Offline</span><strong>${summary.offline}</strong></div>
            <div class="legend-row"><span class="status-dot" style="background: var(--amber);"></span><span>Atencao</span><strong>${attention}</strong></div>
            <div class="mini-text">Total: ${summary.total} dispositivo(s)</div>
          </div>
        </div>
      </section>
    `;
  }

  function renderTimeline() {
    const rows = asArray(state.devices).slice(0, 6).map((device) => {
      const cls = device.current_status === "offline" ? "offline" : (device.criticality === "alta" || device.criticality === "critica" ? "attention" : "");
      return `
        <div class="timeline-row">
          <strong>${escapeHtml(device.name)}</strong>
          <div class="timeline-track"><div class="timeline-fill ${cls}"></div></div>
        </div>
      `;
    }).join("");

    return `
      <section class="panel">
        <div class="section-header">
          <h2 class="section-title">Linha do tempo de disponibilidade (24h)</h2>
          <div class="mini-text">Online - Offline - Atencao</div>
        </div>
        <div class="timeline">${rows || `<div class="empty-state">Sem dispositivos cadastrados.</div>`}</div>
      </section>
    `;
  }

  function renderRecentEvents() {
    const events = filteredEvents().slice(0, 5);
    return `
      <section class="panel">
        <div class="section-header">
          <h2 class="section-title">Historico recente de eventos</h2>
          <button class="button" data-view="history">Abrir</button>
        </div>
        <div class="table-scroll">
          <table>
            <thead>
              <tr><th>Dispositivo</th><th>Evento</th><th>Data/Hora</th><th>Duracao</th></tr>
            </thead>
            <tbody>
              ${events.map((event) => `
                <tr>
                  <td><span class="status-dot ${event.status === "open" ? "offline" : "online"}"></span> ${escapeHtml(event.device?.name || event.device_id)}</td>
                  <td>${event.status === "open" ? "down_at" : "up_at"}</td>
                  <td>${formatDate(event.status === "open" ? event.down_at : event.up_at)}</td>
                  <td>${event.status === "open" ? timeAgo(event.down_at) : formatDuration(event.duration_seconds)}</td>
                </tr>
              `).join("") || `<tr><td colspan="4"><div class="empty-state">Sem eventos registrados.</div></td></tr>`}
            </tbody>
          </table>
        </div>
      </section>
    `;
  }

  function renderAlertsPage() {
    const alerts = openAlerts();
    return `
      ${renderMetrics()}
      <section class="panel">
        <div class="section-header">
          <h2 class="section-title">Alertas criticos em aberto</h2>
          ${canOperate() ? `<button class="button" data-action="run-monitor">Atualizar monitoramento</button>` : ""}
        </div>
        <div class="alert-list">
          ${alerts.map(renderAlertItem).join("") || `<div class="empty-state">Nenhum alerta aberto neste momento.</div>`}
        </div>
      </section>
    `;
  }

  function renderHistoryPage() {
    const events = filteredEvents();
    return `
      <section class="table-panel">
        <div class="section-header" style="padding: 18px 18px 0;">
          <h2 class="section-title">Historico de disponibilidade</h2>
          <div class="filters">
            <select class="select" data-history-filter="device">
              ${deviceOptions(state.historyFilters.device, "Todos os dispositivos")}
            </select>
            <select class="select" data-history-filter="status">
              <option value="all"${state.historyFilters.status === "all" ? " selected" : ""}>Todos os status</option>
              <option value="open"${state.historyFilters.status === "open" ? " selected" : ""}>Aberto</option>
              <option value="resolved"${state.historyFilters.status === "resolved" ? " selected" : ""}>Resolvido</option>
            </select>
            <select class="select" data-history-filter="criticality">
              <option value="all"${state.historyFilters.criticality === "all" ? " selected" : ""}>Todas as criticidades</option>
              <option value="baixa"${state.historyFilters.criticality === "baixa" ? " selected" : ""}>Baixa</option>
              <option value="media"${state.historyFilters.criticality === "media" ? " selected" : ""}>Media</option>
              <option value="alta"${state.historyFilters.criticality === "alta" ? " selected" : ""}>Alta</option>
              <option value="critica"${state.historyFilters.criticality === "critica" ? " selected" : ""}>Critica</option>
            </select>
          </div>
        </div>
        <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Dispositivo</th>
                <th>Tipo do evento</th>
                <th>Data e hora</th>
                <th>Duracao</th>
                <th>Criticidade</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              ${events.map(renderHistoryRow).join("") || `<tr><td colspan="6"><div class="empty-state">Sem eventos para os filtros atuais.</div></td></tr>`}
            </tbody>
          </table>
        </div>
      </section>
    `;
  }

  function renderHistoryRow(event) {
    const type = event.status === "open" ? "down" : "up";
    const date = event.status === "open" ? event.down_at : event.up_at;
    return `
      <tr>
        <td>${escapeHtml(event.device?.name || event.device_id)}</td>
        <td>${type}</td>
        <td>${formatDate(date)}</td>
        <td>${event.status === "open" ? timeAgo(event.down_at) : formatDuration(event.duration_seconds)}</td>
        <td><span class="badge ${criticalityClass(event.criticality)}">${labelCriticality(event.criticality)}</span></td>
        <td><span class="badge ${event.status === "open" ? "offline" : "online"}">${event.status === "open" ? "ABERTO" : "RESOLVIDO"}</span></td>
      </tr>
    `;
  }

  function renderUsersPage() {
    if (!isAdmin()) {
      return `<section class="panel">Apenas administradores podem acessar usuarios.</section>`;
    }

    return `
      <section class="table-panel">
        <div class="section-header" style="padding: 18px 18px 0;">
          <h2 class="section-title">Usuarios e cargos</h2>
          <button class="button primary" data-action="new-user">Novo usuario</button>
        </div>
        <div class="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Nome</th>
                <th>Email</th>
                <th>Cargo</th>
                <th>Status</th>
                <th>Ultimo login</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              ${asArray(state.users).map(renderUserRow).join("") || `<tr><td colspan="6"><div class="empty-state">Nenhum usuario encontrado.</div></td></tr>`}
            </tbody>
          </table>
        </div>
      </section>
    `;
  }

  function renderUserRow(user) {
    const isSelf = state.auth.user && state.auth.user.id === user.id;
    return `
      <tr>
        <td><strong>${escapeHtml(user.name)}</strong>${isSelf ? ` <span class="badge inactive">VOCE</span>` : ""}</td>
        <td>${escapeHtml(user.email)}</td>
        <td><span class="badge ${user.role === "admin" ? "critical" : user.role === "operator" ? "high" : "low"}">${roleLabel(user.role)}</span></td>
        <td><span class="badge ${user.status === "active" ? "online" : "inactive"}">${user.status === "active" ? "ATIVO" : "INATIVO"}</span></td>
        <td>${user.last_login_at ? timeAgo(user.last_login_at) : "Nunca"}</td>
        <td>
          <div class="row-actions">
            <button class="button compact" data-action="edit-user" data-id="${user.id}">Editar</button>
            <button class="button compact danger" data-action="delete-user" data-id="${user.id}" ${isSelf ? "disabled" : ""}>Excluir</button>
          </div>
        </td>
      </tr>
    `;
  }

  function renderModal() {
    const device = state.modal.device || {
      name: "",
      host: "",
      type: "Servidor",
      location: "",
      criticality: "media",
      is_active: true
    };
    const isEdit = Boolean(device.id);

    return `
      <div class="modal-backdrop">
        <form class="modal" id="device-form">
          <div class="modal-header">
            <h2 class="section-title">${isEdit ? "Editar dispositivo" : "Novo dispositivo"}</h2>
            <button class="button icon-only" type="button" data-action="close-modal">X</button>
          </div>
          <div class="form-grid">
            <div class="field">
              <label for="name">Nome do dispositivo</label>
              <input class="input" id="name" name="name" required value="${escapeHtml(device.name)}">
            </div>
            <div class="field">
              <label for="host">IP ou hostname</label>
              <input class="input" id="host" name="host" required value="${escapeHtml(device.host)}" autocomplete="off">
              <div class="field-help">Use apenas o host ou IP, sem http://.</div>
            </div>
            <div class="field">
              <label for="type">Tipo</label>
              <select class="select" id="type" name="type">
                ${["Servidor", "Banco de Dados", "Firewall", "Switch", "Impressora", "Access Point", "Servico", "Outro"].map((type) => `<option value="${type}"${device.type === type ? " selected" : ""}>${type}</option>`).join("")}
              </select>
            </div>
            <div class="field">
              <label for="location">Localizacao</label>
              <input class="input" id="location" name="location" value="${escapeHtml(device.location)}">
            </div>
            <div class="field">
              <label for="criticality">Criticidade</label>
              <select class="select" id="criticality" name="criticality">
                <option value="baixa"${device.criticality === "baixa" ? " selected" : ""}>Baixa</option>
                <option value="media"${device.criticality === "media" ? " selected" : ""}>Media</option>
                <option value="alta"${device.criticality === "alta" ? " selected" : ""}>Alta</option>
                <option value="critica"${device.criticality === "critica" ? " selected" : ""}>Critica</option>
              </select>
            </div>
            <div class="field full">
              <label class="checkbox-field">
                <input type="checkbox" name="is_active" ${device.is_active ? "checked" : ""}>
                Ativo para monitoramento automatico
              </label>
              <div class="field-help">Dispositivos ativos entram nos ciclos de verificacao. Inativos permanecem cadastrados, mas nao sao testados.</div>
            </div>
          </div>
          <div class="modal-footer">
            <button class="button" type="button" data-action="close-modal">Cancelar</button>
            <button class="button primary" type="submit">${isEdit ? "Salvar alteracoes" : "Cadastrar"}</button>
          </div>
        </form>
      </div>
    `;
  }

  function renderUserModal() {
    const user = state.userModal.user || {
      name: "",
      email: "",
      role: "viewer",
      status: "active"
    };
    const isEdit = Boolean(user.id);

    return `
      <div class="modal-backdrop">
        <form class="modal" id="user-form">
          <div class="modal-header">
            <h2 class="section-title">${isEdit ? "Editar usuario" : "Novo usuario"}</h2>
            <button class="button icon-only" type="button" data-action="close-user-modal">X</button>
          </div>
          <div class="form-grid">
            <div class="field">
              <label for="user-name">Nome</label>
              <input class="input" id="user-name" name="name" required value="${escapeHtml(user.name)}">
            </div>
            <div class="field">
              <label for="user-email">Email</label>
              <input class="input" id="user-email" name="email" type="email" required value="${escapeHtml(user.email)}">
            </div>
            <div class="field">
              <label for="user-role">Cargo</label>
              <select class="select" id="user-role" name="role">
                <option value="admin"${user.role === "admin" ? " selected" : ""}>Administrador</option>
                <option value="operator"${user.role === "operator" ? " selected" : ""}>Operador</option>
                <option value="viewer"${user.role === "viewer" ? " selected" : ""}>Visualizador</option>
              </select>
            </div>
            <div class="field">
              <label for="user-status">Status</label>
              <select class="select" id="user-status" name="status">
                <option value="active"${user.status === "active" ? " selected" : ""}>Ativo</option>
                <option value="inactive"${user.status === "inactive" ? " selected" : ""}>Inativo</option>
              </select>
            </div>
            <div class="field full">
              <label for="user-password">${isEdit ? "Nova senha" : "Senha"}</label>
              <input class="input" id="user-password" name="password" type="password" ${isEdit ? "" : "required"} minlength="8" autocomplete="new-password">
              <div class="field-help">${isEdit ? "Deixe em branco para manter a senha atual." : "Minimo de 8 caracteres."}</div>
            </div>
          </div>
          <div class="modal-footer">
            <button class="button" type="button" data-action="close-user-modal">Cancelar</button>
            <button class="button primary" type="submit">${isEdit ? "Salvar usuario" : "Criar usuario"}</button>
          </div>
        </form>
      </div>
    `;
  }

  function bindEvents() {
    app.querySelectorAll("[data-view]").forEach((button) => {
      button.addEventListener("click", async () => {
        state.view = button.dataset.view;
        if (state.view === "users") {
          try {
            await loadUsers();
          } catch (error) {
            setToast(error.message);
          }
        }
        render();
      });
    });

    app.querySelectorAll("[data-filter]").forEach((field) => {
      field.addEventListener("input", () => {
        state.filters[field.dataset.filter] = field.value;
        render();
      });
      field.addEventListener("change", () => {
        state.filters[field.dataset.filter] = field.value;
        render();
      });
    });

    app.querySelectorAll("[data-history-filter]").forEach((field) => {
      field.addEventListener("change", () => {
        state.historyFilters[field.dataset.historyFilter] = field.value;
        render();
      });
    });

    app.querySelectorAll("[data-action]").forEach((button) => {
      button.addEventListener("click", handleAction);
    });

    const form = app.querySelector("#device-form");
    if (form) {
      form.addEventListener("submit", handleDeviceSubmit);
    }

    const userForm = app.querySelector("#user-form");
    if (userForm) {
      userForm.addEventListener("submit", handleUserSubmit);
    }
  }

  async function handleAction(event) {
    const action = event.currentTarget.dataset.action;
    const id = event.currentTarget.dataset.id;

    try {
      if (action === "reload") {
        await loadData();
        return;
      }

      if (action === "logout") {
        await api.post("/api/auth/logout");
        state.auth.user = null;
        state.auth.setupRequired = false;
        state.view = "dashboard";
        state.devices = [];
        state.events = [];
        state.alerts = [];
        state.users = [];
        render();
        return;
      }

      if (action === "new-user") {
        state.userModal = { user: null };
        render();
      }

      if (action === "edit-user") {
        const user = asArray(state.users).find((item) => item.id === id);
        if (user) {
          state.userModal = { user: { ...user } };
          render();
        }
      }

      if (action === "close-user-modal") {
        state.userModal = null;
        render();
      }

      if (action === "delete-user") {
        const user = asArray(state.users).find((item) => item.id === id);
        if (user && window.confirm(`Excluir o usuario ${user.name}?`)) {
          await api.delete(`/api/users/${id}`);
          await loadUsers();
          setToast("Usuario removido.");
          render();
        }
      }

      if (action === "new-device") {
        state.modal = { device: null };
        render();
      }

      if (action === "edit-device") {
        const device = deviceById(id);
        if (device) {
          state.modal = { device: { ...device } };
          render();
        }
      }

      if (action === "close-modal") {
        state.modal = null;
        render();
      }

      if (action === "delete-device") {
        const device = deviceById(id);
        if (device && window.confirm(`Excluir ${device.name} e seus eventos vinculados?`)) {
          await api.delete(`/api/devices/${id}`);
          await loadData({ silent: true });
          setToast("Dispositivo removido.");
        }
      }

      if (action === "check-device") {
        await api.post(`/api/devices/${id}/check`);
        await loadData({ silent: true });
        setToast("Verificacao concluida.");
      }

      if (action === "run-monitor") {
        await api.post("/api/monitor/run");
        await loadData({ silent: true });
        setToast("Monitoramento executado.");
      }

      if (action === "resolve-alert") {
        await api.post(`/api/alerts/${id}/resolve`);
        await loadData({ silent: true });
        setToast("Alerta marcado como resolvido.");
      }
    } catch (error) {
      setToast(error.message);
    }
  }

  async function handleSetupSubmit(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const payload = {
      name: form.get("name"),
      email: form.get("email"),
      password: form.get("password")
    };

    try {
      state.error = "";
      const response = await api.post("/api/auth/setup", payload);
      state.auth.user = response.user;
      state.auth.setupRequired = false;
      await loadData({ silent: true });
      setToast("Administrador criado.");
    } catch (error) {
      state.error = error.message;
      render();
    }
  }

  async function handleLoginSubmit(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const payload = {
      email: form.get("email"),
      password: form.get("password")
    };

    try {
      state.error = "";
      const response = await api.post("/api/auth/login", payload);
      state.auth.user = response.user;
      state.auth.setupRequired = false;
      await loadData({ silent: true });
      setToast("Login realizado.");
    } catch (error) {
      state.error = error.message;
      render();
    }
  }

  async function handleDeviceSubmit(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const payload = {
      name: form.get("name"),
      host: form.get("host"),
      type: form.get("type"),
      location: form.get("location"),
      criticality: form.get("criticality"),
      is_active: form.get("is_active") === "on"
    };

    try {
      if (state.modal.device && state.modal.device.id) {
        await api.put(`/api/devices/${state.modal.device.id}`, payload);
        setToast("Dispositivo atualizado.");
      } else {
        const created = await api.post("/api/devices", payload);
        if (payload.is_active && created?.id) {
          await api.post(`/api/devices/${created.id}/check`);
          setToast("Dispositivo cadastrado e verificado.");
        } else {
          setToast("Dispositivo cadastrado.");
        }
      }
      state.modal = null;
      await loadData({ silent: true });
    } catch (error) {
      setToast(error.message);
    }
  }

  async function handleUserSubmit(event) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const password = form.get("password");
    const payload = {
      name: form.get("name"),
      email: form.get("email"),
      role: form.get("role"),
      status: form.get("status")
    };
    if (password) {
      payload.password = password;
    }

    try {
      if (state.userModal.user && state.userModal.user.id) {
        await api.put(`/api/users/${state.userModal.user.id}`, payload);
        setToast("Usuario atualizado.");
      } else {
        payload.password = password;
        await api.post("/api/users", payload);
        setToast("Usuario criado.");
      }
      state.userModal = null;
      await loadUsers();
      render();
    } catch (error) {
      setToast(error.message);
    }
  }

  loadAuthStatus();
  window.setInterval(() => {
    if (state.auth.user && !state.modal && !state.userModal) {
      loadData({ silent: true });
    }
  }, 5000);
})();

