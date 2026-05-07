# Sword 2.0

<p align="center">
  <img src="./public/sword-logo.svg" alt="Sword logo" width="96">
</p>

<p align="center">
  Painel local de monitoramento de infraestrutura para redes internas.
</p>

<p align="center">
  <strong>Criado por Lucas Lima</strong> | <strong>LucasLimaSzDev</strong>
</p>

---

## Visao geral

Evolucao do MVP com autenticacao, usuarios e papeis operacionais.

Sword foi criado e desenvolvido por Lucas Lima (LucasLimaSzDev) como uma
solucao local para acompanhar disponibilidade, ativos, alertas e incidentes de
infraestrutura.

## Destaques da versao

- Setup do primeiro administrador.
- Login e logout com sessao em cookie HttpOnly.
- Cargos de Administrador, Operador e Visualizador.
- Gestao de usuarios para administradores.
- Senhas com PBKDF2-SHA256 e salt individual.

## Como executar

Crie um store local limpo a partir do exemplo publico:

~~~powershell
Copy-Item .\data\store.example.json .\data\store.json
~~~

O arquivo data/store.json e local e privado. Ele nunca deve ser enviado para
o GitHub.

~~~powershell
.\server.ps1
~~~

Depois abra:

~~~text
http://localhost:8787
~~~

Parametros opcionais:

~~~powershell
.\server.ps1 -Port 8787 -CheckIntervalSeconds 30 -Attempts 3 -TimeoutMs 900
~~~

## Seguranca e privacidade

- Nao publique data/store.json.
- Nao publique backups, logs, archives ou exports com dados reais.
- Use somente data/store.example.json como exemplo publico.
- Mantenha o Sword em rede local, VPN ou reverse proxy autenticado quando usado
  fora da maquina local.

## Estrutura

~~~text
server.ps1              Backend HTTP, API e monitoramento
data/store.example.json Store publico limpo
data/store.json         Store local privado, ignorado no GitHub
public/index.html       Shell da aplicacao
public/styles.css       Interface responsiva
public/app.js           Frontend SPA
public/sword-logo.svg   Identidade visual
~~~

## Tech stack

- PowerShell
- HTML
- CSS
- JavaScript
- JSON local

## Licenca

Copyright (c) 2026 Lucas Lima. Todos os direitos reservados.
