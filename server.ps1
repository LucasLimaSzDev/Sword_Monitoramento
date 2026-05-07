param(
  [int]$Port = 8787,
  [int]$CheckIntervalSeconds = 30,
  [int]$Attempts = 3,
  [int]$TimeoutMs = 900
)

$ErrorActionPreference = "Stop"

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$PublicDir = Join-Path $Root "public"
$DataFile = Join-Path $Root "data\store.json"

function Get-NowIso {
  return (Get-Date).ToString("o")
}

function Get-CleanArray($Items) {
  if ($null -eq $Items) {
    return
  }

  foreach ($item in @($Items)) {
    if ($null -ne $item) {
      $item
    }
  }
}

function Get-RandomBytes([int]$Length) {
  $bytes = New-Object byte[] $Length
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  return $bytes
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
  return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-EntityId([string]$Prefix) {
  $stamp = (Get-Date).ToString("yyyyMMddHHmmssfff")
  $suffix = -join ((48..57) + (97..102) | Get-Random -Count 6 | ForEach-Object {[char]$_})
  return "${Prefix}_${stamp}_${suffix}"
}

function Read-Store {
  if (-not (Test-Path -LiteralPath $DataFile)) {
    throw "Arquivo de dados nao encontrado: $DataFile"
  }

  $json = Get-Content -LiteralPath $DataFile -Raw
  $store = $json | ConvertFrom-Json
  $store.devices = @(Get-CleanArray $store.devices)
  $store.status_events = @(Get-CleanArray $store.status_events)
  $store.alerts = @(Get-CleanArray $store.alerts)
  $store | Add-Member -NotePropertyName users -NotePropertyValue @(Get-CleanArray $store.users) -Force
  $store | Add-Member -NotePropertyName sessions -NotePropertyValue @(Get-CleanArray $store.sessions) -Force
  $store | Add-Member -NotePropertyName audit_logs -NotePropertyValue @(Get-CleanArray $store.audit_logs) -Force
  return $store
}

function Save-Store($Store) {
  $Store.devices = @(Get-CleanArray $Store.devices)
  $Store.status_events = @(Get-CleanArray $Store.status_events)
  $Store.alerts = @(Get-CleanArray $Store.alerts)
  $Store | Add-Member -NotePropertyName users -NotePropertyValue @(Get-CleanArray $Store.users) -Force
  $Store | Add-Member -NotePropertyName sessions -NotePropertyValue @(Get-CleanArray $Store.sessions) -Force
  $Store | Add-Member -NotePropertyName audit_logs -NotePropertyValue @(Get-CleanArray $Store.audit_logs) -Force
  ConvertTo-Json -InputObject $Store -Depth 20 -Compress | Set-Content -LiteralPath $DataFile -Encoding UTF8
}

function Read-RequestJson($Request) {
  if ($Request.HasEntityBody -ne $true -and [string]::IsNullOrWhiteSpace($Request.ContentBody)) {
    return $null
  }

  if ($null -ne $Request.ContentBody) {
    if ([string]::IsNullOrWhiteSpace($Request.ContentBody)) {
      return $null
    }
    return $Request.ContentBody | ConvertFrom-Json
  }

  $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
  $body = $reader.ReadToEnd()
  $reader.Close()

  if ([string]::IsNullOrWhiteSpace($body)) {
    return $null
  }

  return $body | ConvertFrom-Json
}

function Send-Raw($Context, [byte[]]$Bytes, [string]$ContentType, [int]$StatusCode = 200, [string[]]$ExtraHeaders = @()) {
  $reason = switch ($StatusCode) {
    200 { "OK" }
    201 { "Created" }
    400 { "Bad Request" }
    401 { "Unauthorized" }
    403 { "Forbidden" }
    404 { "Not Found" }
    500 { "Internal Server Error" }
    default { "OK" }
  }

  $extra = ""
  foreach ($line in $ExtraHeaders) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
      $extra += "$line`r`n"
    }
  }

  $header = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n$extra`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $Context.Stream.Write($headerBytes, 0, $headerBytes.Length)
  $Context.Stream.Write($Bytes, 0, $Bytes.Length)
  $Context.Stream.Flush()
  $Context.Client.Close()
}

function Send-Json($Context, $Data, [int]$StatusCode = 200, [string[]]$ExtraHeaders = @()) {
  $json = ConvertTo-Json -InputObject $Data -Depth 20 -Compress
  if ([string]::IsNullOrWhiteSpace($json)) {
    $json = "null"
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Send-Raw $Context $bytes "application/json; charset=utf-8" $StatusCode $ExtraHeaders
}

function Send-JsonArray($Context, $Items, [int]$StatusCode = 200, [string[]]$ExtraHeaders = @()) {
  $array = @(Get-CleanArray $Items)
  if ($array.Count -eq 0) {
    $json = "[]"
  } else {
    $json = ConvertTo-Json -InputObject $array -Depth 20 -Compress
  }

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Send-Raw $Context $bytes "application/json; charset=utf-8" $StatusCode $ExtraHeaders
}

function Send-Text($Context, [string]$Text, [int]$StatusCode = 200) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  Send-Raw $Context $bytes "text/plain; charset=utf-8" $StatusCode
}

function Send-File($Context, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Send-Text $Context "Arquivo nao encontrado" 404
    return
  }

  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  $contentType = switch ($extension) {
    ".html" { "text/html; charset=utf-8" }
    ".css" { "text/css; charset=utf-8" }
    ".js" { "application/javascript; charset=utf-8" }
    ".json" { "application/json; charset=utf-8" }
    ".svg" { "image/svg+xml" }
    ".png" { "image/png" }
    ".jpg" { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    default { "application/octet-stream" }
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  Send-Raw $Context $bytes $contentType 200
}

function Test-HostOnline([string]$HostName, [int]$AttemptCount, [int]$PingTimeoutMs) {
  if ([string]::IsNullOrWhiteSpace($HostName)) {
    return $false
  }

  $ping = [System.Net.NetworkInformation.Ping]::new()
  try {
    for ($i = 0; $i -lt $AttemptCount; $i++) {
      try {
        $reply = $ping.Send($HostName, $PingTimeoutMs)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
          return $true
        }
      } catch {
        Start-Sleep -Milliseconds 120
      }
    }
  } finally {
    $ping.Dispose()
  }

  return $false
}

function Get-OpenEvent($Store, [string]$DeviceId) {
  return @(Get-CleanArray $Store.status_events) |
    Where-Object { $_.device_id -eq $DeviceId -and $_.status -eq "open" } |
    Select-Object -First 1
}

function Get-DeviceById($Store, [string]$DeviceId) {
  return @(Get-CleanArray $Store.devices) | Where-Object { $_.id -eq $DeviceId } | Select-Object -First 1
}

function Test-AllowedValue([string]$Value, [string[]]$Allowed) {
  return $Allowed -contains "$Value".ToLowerInvariant()
}

function Get-PasswordHash([string]$Password) {
  $iterations = 120000
  $salt = Get-RandomBytes 16
  $derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
  try {
    $hash = $derive.GetBytes(32)
  } finally {
    $derive.Dispose()
  }

  return "pbkdf2-sha256:${iterations}:$([Convert]::ToBase64String($salt)):$([Convert]::ToBase64String($hash))"
}

function Test-PasswordHash([string]$Password, [string]$StoredHash) {
  if ([string]::IsNullOrWhiteSpace($Password) -or [string]::IsNullOrWhiteSpace($StoredHash)) {
    return $false
  }

  $parts = @($StoredHash -split ":")
  if ($parts.Count -ne 4 -or $parts[0] -ne "pbkdf2-sha256") {
    return $false
  }

  try {
    $iterations = [int]$parts[1]
    $salt = [Convert]::FromBase64String($parts[2])
    $expected = [Convert]::FromBase64String($parts[3])
    $derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
      $actual = $derive.GetBytes($expected.Length)
    } finally {
      $derive.Dispose()
    }
    if ($actual.Length -ne $expected.Length) {
      return $false
    }

    $diff = 0
    for ($i = 0; $i -lt $actual.Length; $i++) {
      $diff = $diff -bor ($actual[$i] -bxor $expected[$i])
    }
    return $diff -eq 0
  } catch {
    return $false
  }
}

function Get-TokenHash([string]$Token) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
    return [Convert]::ToBase64String($sha.ComputeHash($bytes))
  } finally {
    $sha.Dispose()
  }
}

function New-SessionToken {
  return ConvertTo-Base64Url (Get-RandomBytes 32)
}

function Get-CookieValue($Request, [string]$Name) {
  if ($null -eq $Request.Headers -or -not $Request.Headers.ContainsKey("cookie")) {
    return $null
  }

  foreach ($part in @($Request.Headers["cookie"] -split ";")) {
    $pair = @($part.Trim() -split "=", 2)
    if ($pair.Count -eq 2 -and $pair[0] -eq $Name) {
      return $pair[1]
    }
  }

  return $null
}

function Get-PublicUser($User) {
  if ($null -eq $User) {
    return $null
  }

  return [pscustomobject][ordered]@{
    id = $User.id
    name = $User.name
    email = $User.email
    role = $User.role
    status = $User.status
    created_at = $User.created_at
    updated_at = $User.updated_at
    last_login_at = $User.last_login_at
  }
}

function Get-RoleLabel([string]$Role) {
  switch ("$Role".ToLowerInvariant()) {
    "admin" { "Administrador" }
    "operator" { "Operador" }
    "viewer" { "Visualizador" }
    default { $Role }
  }
}

function Test-RoleAllowed([string]$Role, [string[]]$AllowedRoles) {
  return $AllowedRoles -contains "$Role".ToLowerInvariant()
}

function Get-CurrentUser($Store, $Request) {
  $token = Get-CookieValue $Request "monitor_session"
  if ([string]::IsNullOrWhiteSpace($token)) {
    return $null
  }

  $tokenHash = Get-TokenHash $token
  $now = Get-Date
  $session = @(Get-CleanArray $Store.sessions) |
    Where-Object { $_.token_hash -eq $tokenHash -and $_.status -eq "active" } |
    Select-Object -First 1

  if ($null -eq $session) {
    return $null
  }

  if ([datetime]::Parse($session.expires_at) -lt $now) {
    $session.status = "expired"
    return $null
  }

  $user = @(Get-CleanArray $Store.users) |
    Where-Object { $_.id -eq $session.user_id -and $_.status -eq "active" } |
    Select-Object -First 1

  return $user
}

function Get-UserByEmail($Store, [string]$Email) {
  $normalized = "$Email".Trim().ToLowerInvariant()
  return @(Get-CleanArray $Store.users) |
    Where-Object { "$($_.email)".ToLowerInvariant() -eq $normalized } |
    Select-Object -First 1
}

function Get-UserById($Store, [string]$UserId) {
  return @(Get-CleanArray $Store.users) |
    Where-Object { $_.id -eq $UserId } |
    Select-Object -First 1
}

function Add-AuditLog($Store, $User, [string]$Action, [string]$EntityType, [string]$EntityId, $Metadata = $null) {
  $entry = [pscustomobject][ordered]@{
    id = New-EntityId "aud"
    user_id = if ($null -eq $User) { $null } else { $User.id }
    action = $Action
    entity_type = $EntityType
    entity_id = $EntityId
    created_at = Get-NowIso
    metadata = $Metadata
  }
  $Store.audit_logs = @(Get-CleanArray $Store.audit_logs) + $entry
}

function Get-UserBodyError($Body, [bool]$IsCreate) {
  if ($null -eq $Body) {
    return "Corpo da requisicao invalido."
  }

  if ($IsCreate -or $null -ne $Body.name) {
    if ([string]::IsNullOrWhiteSpace($Body.name) -or "$($Body.name)".Trim().Length -gt 80) {
      return "Nome e obrigatorio e deve ter ate 80 caracteres."
    }
  }

  if ($IsCreate -or $null -ne $Body.email) {
    if ([string]::IsNullOrWhiteSpace($Body.email) -or "$($Body.email)" -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") {
      return "Email invalido."
    }
  }

  if ($IsCreate -or $null -ne $Body.role) {
    if (-not (Test-AllowedValue "$($Body.role)" @("admin", "operator", "viewer"))) {
      return "Cargo invalido."
    }
  }

  if ($IsCreate -or $null -ne $Body.password) {
    if ([string]::IsNullOrWhiteSpace($Body.password) -or "$($Body.password)".Length -lt 8) {
      return "Senha deve ter pelo menos 8 caracteres."
    }
  }

  if ($null -ne $Body.status -and -not (Test-AllowedValue "$($Body.status)" @("active", "inactive"))) {
    return "Status de usuario invalido."
  }

  return $null
}

function New-UserFromBody($Body, [string]$Now) {
  return [pscustomobject][ordered]@{
    id = New-EntityId "usr"
    name = "$($Body.name)".Trim()
    email = "$($Body.email)".Trim().ToLowerInvariant()
    password_hash = Get-PasswordHash "$($Body.password)"
    role = "$($Body.role)".Trim().ToLowerInvariant()
    status = "active"
    created_at = $Now
    updated_at = $Now
    last_login_at = $null
  }
}

function New-Session($Store, $User, $Request) {
  $token = New-SessionToken
  $now = Get-Date
  $session = [pscustomobject][ordered]@{
    id = New-EntityId "ses"
    user_id = $User.id
    token_hash = Get-TokenHash $token
    status = "active"
    created_at = $now.ToString("o")
    expires_at = $now.AddHours(8).ToString("o")
    ip_address = if ($null -eq $Request.RemoteEndPoint) { $null } else { "$($Request.RemoteEndPoint)" }
    user_agent = if ($Request.Headers.ContainsKey("user-agent")) { $Request.Headers["user-agent"] } else { $null }
  }
  $Store.sessions = @(Get-CleanArray $Store.sessions | Where-Object { $_.status -eq "active" -and [datetime]::Parse($_.expires_at) -gt $now }) + $session
  return [pscustomobject]@{ token = $token; session = $session }
}

function Get-SessionCookieHeader([string]$Token) {
  return "Set-Cookie: monitor_session=$Token; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800"
}

function Get-ClearSessionCookieHeader {
  return "Set-Cookie: monitor_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"
}

function Get-DeviceBodyError($Body, [bool]$IsCreate) {
  if ($null -eq $Body) {
    return "Corpo da requisicao invalido."
  }

  if ($IsCreate -or $null -ne $Body.name) {
    if ([string]::IsNullOrWhiteSpace($Body.name) -or "$($Body.name)".Length -gt 80) {
      return "Nome e obrigatorio e deve ter ate 80 caracteres."
    }
  }

  if ($IsCreate -or $null -ne $Body.host) {
    if ([string]::IsNullOrWhiteSpace($Body.host) -or "$($Body.host)".Length -gt 120) {
      return "IP ou hostname e obrigatorio e deve ter ate 120 caracteres."
    }
    if ("$($Body.host)" -notmatch "^[A-Za-z0-9_.:-]+$") {
      return "IP ou hostname deve conter apenas letras, numeros, ponto, hifen, underline ou dois-pontos."
    }
  }

  if ($IsCreate -or $null -ne $Body.criticality) {
    if (-not (Test-AllowedValue "$($Body.criticality)" @("baixa", "media", "alta", "critica"))) {
      return "Criticidade invalida."
    }
  }

  if ($null -ne $Body.current_status -and -not (Test-AllowedValue "$($Body.current_status)" @("online", "offline"))) {
    return "Status atual invalido."
  }

  foreach ($field in @("type", "location")) {
    if ($null -ne $Body.$field -and "$($Body.$field)".Length -gt 80) {
      return "Campo $field deve ter ate 80 caracteres."
    }
  }

  return $null
}

function New-StatusEvent($Store, $Device, [string]$Now) {
  $event = [pscustomobject][ordered]@{
    id = New-EntityId "evt"
    device_id = $Device.id
    down_at = $Now
    up_at = $null
    duration_seconds = $null
    status = "open"
    criticality = $Device.criticality
    created_at = $Now
    updated_at = $Now
  }

  $Store.status_events = @(Get-CleanArray $Store.status_events) + $event
  return $event
}

function New-CriticalAlert($Store, $Device, $Event, [string]$Now) {
  $criticality = "$($Device.criticality)".ToLowerInvariant()
  if ($criticality -notin @("alta", "critica")) {
    return
  }

  $priority = if ($criticality -eq "critica") { "critical" } else { "high" }
  $label = if ($criticality -eq "critica") { "CRITICO" } else { "ALTA" }
  $alert = [pscustomobject][ordered]@{
    id = New-EntityId "alt"
    device_id = $Device.id
    status_event_id = $Event.id
    title = "[$label] $($Device.name) offline"
    message = "$($Device.name) esta offline em $($Device.location)."
    priority = $priority
    status = "open"
    created_at = $Now
    resolved_at = $null
  }

  $Store.alerts = @(Get-CleanArray $Store.alerts) + $alert
}

function Resolve-EventAndAlerts($Store, $Device, [string]$Now) {
  $openEvent = Get-OpenEvent $Store $Device.id
  if ($null -eq $openEvent) {
    return
  }

  $downAt = [datetime]::Parse($openEvent.down_at)
  $upAt = [datetime]::Parse($Now)
  $openEvent.up_at = $Now
  $openEvent.duration_seconds = [int][math]::Max(0, ($upAt - $downAt).TotalSeconds)
  $openEvent.status = "resolved"
  $openEvent.updated_at = $Now

  foreach ($alert in @(Get-CleanArray $Store.alerts)) {
    if ($alert.status_event_id -eq $openEvent.id -and $alert.status -eq "open") {
      $alert.status = "resolved"
      $alert.resolved_at = $Now
    }
  }
}

function Apply-DeviceStatus($Store, $Device, [bool]$IsOnline, [string]$Now) {
  $nextStatus = if ($IsOnline) { "online" } else { "offline" }
  $previousStatus = "$($Device.current_status)".ToLowerInvariant()

  if ($nextStatus -eq "offline") {
    $openEvent = Get-OpenEvent $Store $Device.id
    if ($null -eq $openEvent) {
      $event = New-StatusEvent $Store $Device $Now
      New-CriticalAlert $Store $Device $event $Now
    }
  } elseif ($previousStatus -ne $nextStatus) {
      Resolve-EventAndAlerts $Store $Device $Now
  }

  $Device.current_status = $nextStatus
  $Device.last_check_at = $Now
  $Device.updated_at = $Now
}

function Invoke-DeviceCheck($Store, $Device) {
  if ($Device.is_active -ne $true) {
    return [pscustomobject]@{
      device_id = $Device.id
      checked = $false
      reason = "inactive"
      status = $Device.current_status
    }
  }

  $now = Get-NowIso
  $isOnline = Test-HostOnline $Device.host $Attempts $TimeoutMs
  Apply-DeviceStatus $Store $Device $isOnline $now

  return [pscustomobject]@{
    device_id = $Device.id
    checked = $true
    status = $Device.current_status
    checked_at = $now
  }
}

function Invoke-MonitorCycle {
  $store = Read-Store
  $results = @()

  foreach ($device in @(Get-CleanArray $store.devices)) {
    if ($device.is_active -eq $true) {
      $results += Invoke-DeviceCheck $store $device
    }
  }

  Save-Store $store
  return $results
}

function Get-Summary($Store) {
  $activeDevices = @(Get-CleanArray $Store.devices) | Where-Object { $_.is_active -eq $true }
  $online = @($activeDevices | Where-Object { $_.current_status -eq "online" })
  $offline = @($activeDevices | Where-Object { $_.current_status -eq "offline" })
  $criticalOffline = @($offline | Where-Object { "$($_.criticality)".ToLowerInvariant() -in @("alta", "critica") })
  $openAlerts = @(Get-CleanArray $Store.alerts | Where-Object { $_.status -eq "open" })

  return [pscustomobject]@{
    total = @($activeDevices).Count
    online = $online.Count
    offline = $offline.Count
    critical_offline = $criticalOffline.Count
    open_alerts = $openAlerts.Count
    generated_at = Get-NowIso
  }
}

function New-DeviceFromBody($Body, [string]$Now) {
  $isActive = if ($null -eq $Body.is_active) { $true } else { [bool]$Body.is_active }
  return [pscustomobject][ordered]@{
    id = New-EntityId "dev"
    name = "$($Body.name)".Trim()
    host = "$($Body.host)".Trim()
    type = if ([string]::IsNullOrWhiteSpace($Body.type)) { "Servidor" } else { "$($Body.type)".Trim() }
    location = if ([string]::IsNullOrWhiteSpace($Body.location)) { "Nao informado" } else { "$($Body.location)".Trim() }
    criticality = if ([string]::IsNullOrWhiteSpace($Body.criticality)) { "media" } else { "$($Body.criticality)".Trim().ToLowerInvariant() }
    current_status = if ($Body.current_status) { "$($Body.current_status)".ToLowerInvariant() } else { "offline" }
    is_active = $isActive
    last_check_at = $null
    created_at = $Now
    updated_at = $Now
  }
}

function Update-DeviceFromBody($Device, $Body, [string]$Now) {
  foreach ($field in @("name", "host", "type", "location", "criticality", "current_status")) {
    if ($null -ne $Body.$field) {
      $value = "$($Body.$field)".Trim()
      if ($field -in @("criticality", "current_status")) {
        $value = $value.ToLowerInvariant()
      }
      $Device.$field = $value
    }
  }

  if ($null -ne $Body.is_active) {
    $Device.is_active = [bool]$Body.is_active
  }

  $Device.updated_at = $Now
}

function Handle-ApiRequest($Context) {
  $request = $Context.Request
  $method = $request.HttpMethod.ToUpperInvariant()
  $path = $request.Url.AbsolutePath.TrimEnd("/")
  if ($path -eq "") { $path = "/" }
  $segments = @($path.Trim("/").Split("/", [System.StringSplitOptions]::RemoveEmptyEntries))

  try {
    $store = Read-Store

    if ($method -eq "GET" -and $path -eq "/api/health") {
      Send-Json $Context ([pscustomobject]@{ ok = $true; now = Get-NowIso })
      return
    }

    if ($method -eq "GET" -and $path -eq "/api/auth/status") {
      $currentUser = Get-CurrentUser $store $request
      Save-Store $store
      Send-Json $Context ([pscustomobject]@{
        setup_required = @(Get-CleanArray $store.users).Count -eq 0
        authenticated = $null -ne $currentUser
        user = Get-PublicUser $currentUser
        roles = @(
          [pscustomobject]@{ value = "admin"; label = "Administrador" },
          [pscustomobject]@{ value = "operator"; label = "Operador" },
          [pscustomobject]@{ value = "viewer"; label = "Visualizador" }
        )
      })
      return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/setup") {
      if (@(Get-CleanArray $store.users).Count -gt 0) {
        Send-Json $Context ([pscustomobject]@{ error = "Administrador inicial ja foi criado." }) 403
        return
      }

      $body = Read-RequestJson $request
      if ($null -eq $body) {
        Send-Json $Context ([pscustomobject]@{ error = "Corpo da requisicao invalido." }) 400
        return
      }
      $body | Add-Member -NotePropertyName role -NotePropertyValue "admin" -Force
      $bodyError = Get-UserBodyError $body $true
      if ($null -ne $bodyError) {
        Send-Json $Context ([pscustomobject]@{ error = $bodyError }) 400
        return
      }

      $now = Get-NowIso
      $user = New-UserFromBody $body $now
      $store.users = @(Get-CleanArray $store.users) + $user
      $sessionResult = New-Session $store $user $request
      $user.last_login_at = $now
      Add-AuditLog $store $user "auth.setup" "user" $user.id ([pscustomobject]@{ role = $user.role })
      Save-Store $store
      Send-Json $Context ([pscustomobject]@{ ok = $true; user = Get-PublicUser $user }) 201 @((Get-SessionCookieHeader $sessionResult.token))
      return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/login") {
      $body = Read-RequestJson $request
      if ($null -eq $body -or [string]::IsNullOrWhiteSpace($body.email) -or [string]::IsNullOrWhiteSpace($body.password)) {
        Send-Json $Context ([pscustomobject]@{ error = "Informe email e senha." }) 400
        return
      }

      $user = Get-UserByEmail $store "$($body.email)"
      if ($null -eq $user -or $user.status -ne "active" -or -not (Test-PasswordHash "$($body.password)" "$($user.password_hash)")) {
        Send-Json $Context ([pscustomobject]@{ error = "Email ou senha invalidos." }) 401
        return
      }

      $sessionResult = New-Session $store $user $request
      $user.last_login_at = Get-NowIso
      $user.updated_at = Get-NowIso
      Add-AuditLog $store $user "auth.login" "user" $user.id $null
      Save-Store $store
      Send-Json $Context ([pscustomobject]@{ ok = $true; user = Get-PublicUser $user }) 200 @((Get-SessionCookieHeader $sessionResult.token))
      return
    }

    if ($method -eq "POST" -and $path -eq "/api/auth/logout") {
      $token = Get-CookieValue $request "monitor_session"
      if (-not [string]::IsNullOrWhiteSpace($token)) {
        $tokenHash = Get-TokenHash $token
        foreach ($session in @(Get-CleanArray $store.sessions)) {
          if ($session.token_hash -eq $tokenHash) {
            $session.status = "revoked"
          }
        }
        Save-Store $store
      }
      Send-Json $Context ([pscustomobject]@{ ok = $true }) 200 @((Get-ClearSessionCookieHeader))
      return
    }

    $currentUser = Get-CurrentUser $store $request
    if ($null -eq $currentUser) {
      Save-Store $store
      Send-Json $Context ([pscustomobject]@{ error = "Login necessario." }) 401 @((Get-ClearSessionCookieHeader))
      return
    }

    if ($method -eq "GET" -and $path -eq "/api/auth/me") {
      Send-Json $Context ([pscustomobject]@{ user = Get-PublicUser $currentUser })
      return
    }

    if ($method -eq "GET" -and $path -eq "/api/users") {
      if (-not (Test-RoleAllowed $currentUser.role @("admin"))) {
        Send-Json $Context ([pscustomobject]@{ error = "Apenas administradores podem listar usuarios." }) 403
        return
      }

      $users = @(Get-CleanArray $store.users) | ForEach-Object { Get-PublicUser $_ }
      Send-JsonArray $Context $users
      return
    }

    if ($method -eq "POST" -and $path -eq "/api/users") {
      if (-not (Test-RoleAllowed $currentUser.role @("admin"))) {
        Send-Json $Context ([pscustomobject]@{ error = "Apenas administradores podem criar usuarios." }) 403
        return
      }

      $body = Read-RequestJson $request
      $bodyError = Get-UserBodyError $body $true
      if ($null -ne $bodyError) {
        Send-Json $Context ([pscustomobject]@{ error = $bodyError }) 400
        return
      }

      if ($null -ne (Get-UserByEmail $store "$($body.email)")) {
        Send-Json $Context ([pscustomobject]@{ error = "Ja existe usuario com este email." }) 400
        return
      }

      $now = Get-NowIso
      $newUser = New-UserFromBody $body $now
      $store.users = @(Get-CleanArray $store.users) + $newUser
      Add-AuditLog $store $currentUser "users.create" "user" $newUser.id ([pscustomobject]@{ role = $newUser.role })
      Save-Store $store
      Send-Json $Context (Get-PublicUser $newUser) 201
      return
    }

    if ($segments.Count -ge 3 -and $segments[0] -eq "api" -and $segments[1] -eq "users") {
      if (-not (Test-RoleAllowed $currentUser.role @("admin"))) {
        Send-Json $Context ([pscustomobject]@{ error = "Apenas administradores podem gerenciar usuarios." }) 403
        return
      }

      $userId = $segments[2]
      $targetUser = Get-UserById $store $userId
      if ($null -eq $targetUser) {
        Send-Json $Context ([pscustomobject]@{ error = "Usuario nao encontrado." }) 404
        return
      }

      if ($method -eq "PUT" -and $segments.Count -eq 3) {
        $body = Read-RequestJson $request
        $bodyError = Get-UserBodyError $body $false
        if ($null -ne $bodyError) {
          Send-Json $Context ([pscustomobject]@{ error = $bodyError }) 400
          return
        }

        if ($null -ne $body.email) {
          $sameEmail = Get-UserByEmail $store "$($body.email)"
          if ($null -ne $sameEmail -and $sameEmail.id -ne $targetUser.id) {
            Send-Json $Context ([pscustomobject]@{ error = "Ja existe usuario com este email." }) 400
            return
          }
          $targetUser.email = "$($body.email)".Trim().ToLowerInvariant()
        }
        if ($null -ne $body.name) { $targetUser.name = "$($body.name)".Trim() }
        if ($null -ne $body.role) { $targetUser.role = "$($body.role)".Trim().ToLowerInvariant() }
        if ($null -ne $body.status) { $targetUser.status = "$($body.status)".Trim().ToLowerInvariant() }
        if ($null -ne $body.password -and -not [string]::IsNullOrWhiteSpace($body.password)) {
          $targetUser.password_hash = Get-PasswordHash "$($body.password)"
        }

        $activeAdmins = @(Get-CleanArray $store.users | Where-Object { $_.role -eq "admin" -and $_.status -eq "active" })
        if ($activeAdmins.Count -eq 0) {
          Send-Json $Context ([pscustomobject]@{ error = "Deve existir pelo menos um administrador ativo." }) 400
          return
        }

        $targetUser.updated_at = Get-NowIso
        Add-AuditLog $store $currentUser "users.update" "user" $targetUser.id ([pscustomobject]@{ role = $targetUser.role; status = $targetUser.status })
        Save-Store $store
        Send-Json $Context (Get-PublicUser $targetUser)
        return
      }

      if ($method -eq "DELETE" -and $segments.Count -eq 3) {
        if ($targetUser.id -eq $currentUser.id) {
          Send-Json $Context ([pscustomobject]@{ error = "Voce nao pode excluir seu proprio usuario." }) 400
          return
        }

        $remainingAdmins = @(Get-CleanArray $store.users | Where-Object { $_.id -ne $targetUser.id -and $_.role -eq "admin" -and $_.status -eq "active" })
        if ($targetUser.role -eq "admin" -and $remainingAdmins.Count -eq 0) {
          Send-Json $Context ([pscustomobject]@{ error = "Deve existir pelo menos um administrador ativo." }) 400
          return
        }

        $store.users = @(Get-CleanArray $store.users | Where-Object { $_.id -ne $targetUser.id })
        $store.sessions = @(Get-CleanArray $store.sessions | Where-Object { $_.user_id -ne $targetUser.id })
        Add-AuditLog $store $currentUser "users.delete" "user" $targetUser.id $null
        Save-Store $store
        Send-Json $Context ([pscustomobject]@{ ok = $true })
        return
      }
    }

    if ($method -eq "GET" -and $path -eq "/api/summary") {
      Send-Json $Context (Get-Summary $store)
      return
    }

    if ($method -eq "GET" -and $path -eq "/api/devices") {
      Send-JsonArray $Context $store.devices
      return
    }

    if ($method -eq "POST" -and $path -eq "/api/devices") {
      if (-not (Test-RoleAllowed $currentUser.role @("admin", "operator"))) {
        Send-Json $Context ([pscustomobject]@{ error = "Seu cargo nao permite cadastrar dispositivos." }) 403
        return
      }

      $body = Read-RequestJson $request
      $bodyError = Get-DeviceBodyError $body $true
      if ($null -ne $bodyError) {
        Send-Json $Context ([pscustomobject]@{ error = $bodyError }) 400
        return
      }

      $now = Get-NowIso
      $device = New-DeviceFromBody $body $now
      $store.devices = @(Get-CleanArray $store.devices) + $device
      Add-AuditLog $store $currentUser "devices.create" "device" $device.id ([pscustomobject]@{ host = $device.host; criticality = $device.criticality })
      Save-Store $store
      Send-Json $Context $device 201
      return
    }

    if ($segments.Count -ge 3 -and $segments[0] -eq "api" -and $segments[1] -eq "devices") {
      $deviceId = $segments[2]
      $device = Get-DeviceById $store $deviceId
      if ($null -eq $device) {
        Send-Json $Context ([pscustomobject]@{ error = "Dispositivo nao encontrado." }) 404
        return
      }

      if ($method -eq "PUT" -and $segments.Count -eq 3) {
        if (-not (Test-RoleAllowed $currentUser.role @("admin", "operator"))) {
          Send-Json $Context ([pscustomobject]@{ error = "Seu cargo nao permite editar dispositivos." }) 403
          return
        }

        $body = Read-RequestJson $request
        $bodyError = Get-DeviceBodyError $body $false
        if ($null -ne $bodyError) {
          Send-Json $Context ([pscustomobject]@{ error = $bodyError }) 400
          return
        }
        Update-DeviceFromBody $device $body (Get-NowIso)
        Add-AuditLog $store $currentUser "devices.update" "device" $device.id $null
        Save-Store $store
        Send-Json $Context $device
        return
      }

      if ($method -eq "DELETE" -and $segments.Count -eq 3) {
        if (-not (Test-RoleAllowed $currentUser.role @("admin", "operator"))) {
          Send-Json $Context ([pscustomobject]@{ error = "Seu cargo nao permite excluir dispositivos." }) 403
          return
        }

        $eventIds = @(Get-CleanArray $store.status_events | Where-Object { $_.device_id -eq $deviceId } | ForEach-Object { $_.id })
        $store.devices = @(Get-CleanArray $store.devices | Where-Object { $_.id -ne $deviceId })
        $store.status_events = @(Get-CleanArray $store.status_events | Where-Object { $_.device_id -ne $deviceId })
        $store.alerts = @(Get-CleanArray $store.alerts | Where-Object { $_.device_id -ne $deviceId -and $eventIds -notcontains $_.status_event_id })
        Add-AuditLog $store $currentUser "devices.delete" "device" $deviceId $null
        Save-Store $store
        Send-Json $Context ([pscustomobject]@{ ok = $true })
        return
      }

      if ($method -eq "POST" -and $segments.Count -eq 4 -and $segments[3] -eq "check") {
        if (-not (Test-RoleAllowed $currentUser.role @("admin", "operator"))) {
          Send-Json $Context ([pscustomobject]@{ error = "Seu cargo nao permite executar verificacoes." }) 403
          return
        }

        $result = Invoke-DeviceCheck $store $device
        Add-AuditLog $store $currentUser "devices.check" "device" $device.id ([pscustomobject]@{ status = $result.status })
        Save-Store $store
        Send-Json $Context $result
        return
      }
    }

    if ($method -eq "POST" -and $path -eq "/api/monitor/run") {
      if (-not (Test-RoleAllowed $currentUser.role @("admin", "operator"))) {
        Send-Json $Context ([pscustomobject]@{ error = "Seu cargo nao permite executar monitoramento." }) 403
        return
      }

      $results = Invoke-MonitorCycle
      $store = Read-Store
      Add-AuditLog $store $currentUser "monitor.run" "monitor" "cycle" ([pscustomobject]@{ count = @($results).Count })
      Save-Store $store
      Send-Json $Context ([pscustomobject]@{ ok = $true; results = $results })
      return
    }

    if ($method -eq "GET" -and $path -eq "/api/events") {
      Send-JsonArray $Context $store.status_events
      return
    }

    if ($method -eq "GET" -and $path -eq "/api/alerts") {
      Send-JsonArray $Context $store.alerts
      return
    }

    if ($segments.Count -eq 4 -and $method -eq "POST" -and $segments[0] -eq "api" -and $segments[1] -eq "alerts" -and $segments[3] -eq "resolve") {
      if (-not (Test-RoleAllowed $currentUser.role @("admin", "operator"))) {
        Send-Json $Context ([pscustomobject]@{ error = "Seu cargo nao permite resolver alertas." }) 403
        return
      }

      $alertId = $segments[2]
      $alert = @(Get-CleanArray $store.alerts) | Where-Object { $_.id -eq $alertId } | Select-Object -First 1
      if ($null -eq $alert) {
        Send-Json $Context ([pscustomobject]@{ error = "Alerta nao encontrado." }) 404
        return
      }

      $alert.status = "resolved"
      $alert.resolved_at = Get-NowIso
      Add-AuditLog $store $currentUser "alerts.resolve" "alert" $alert.id $null
      Save-Store $store
      Send-Json $Context $alert
      return
    }

    Send-Json $Context ([pscustomobject]@{ error = "Rota nao encontrada." }) 404
  } catch {
    Send-Json $Context ([pscustomobject]@{ error = $_.Exception.Message }) 500
  }
}

function Handle-StaticRequest($Context) {
  $path = $Context.Request.Url.AbsolutePath
  if ($path -eq "/" -or [string]::IsNullOrWhiteSpace($path)) {
    Send-File $Context (Join-Path $PublicDir "index.html")
    return
  }

  $relative = $path.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  $filePath = Join-Path $PublicDir $relative
  $resolvedPublic = [System.IO.Path]::GetFullPath($PublicDir)
  $resolvedFile = [System.IO.Path]::GetFullPath($filePath)

  if (-not $resolvedFile.StartsWith($resolvedPublic, [System.StringComparison]::OrdinalIgnoreCase)) {
    Send-Text $Context "Acesso negado" 403
    return
  }

  if (Test-Path -LiteralPath $resolvedFile -PathType Leaf) {
    Send-File $Context $resolvedFile
  } else {
    Send-File $Context (Join-Path $PublicDir "index.html")
  }
}

function Read-TcpHttpContext($Client) {
  $stream = $Client.GetStream()
  $buffer = New-Object byte[] 8192
  $memory = [System.IO.MemoryStream]::new()
  $headerEnd = -1

  while ($headerEnd -lt 0) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) {
      throw "Requisicao vazia."
    }

    $memory.Write($buffer, 0, $read)
    $text = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
    $headerEnd = $text.IndexOf("`r`n`r`n")
  }

  $data = $memory.ToArray()
  $headerText = [System.Text.Encoding]::ASCII.GetString($data, 0, $headerEnd)
  $headerLines = @($headerText -split "`r`n")
  $requestParts = @($headerLines[0] -split " ")
  if ($requestParts.Count -lt 2) {
    throw "Linha de requisicao invalida."
  }

  $headers = @{}
  if ($headerLines.Count -gt 1) {
    foreach ($line in $headerLines[1..($headerLines.Count - 1)]) {
      $separator = $line.IndexOf(":")
      if ($separator -gt 0) {
        $key = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $line.Substring($separator + 1).Trim()
        $headers[$key] = $value
      }
    }
  }

  $contentLength = 0
  if ($headers.ContainsKey("content-length")) {
    [int]::TryParse($headers["content-length"], [ref]$contentLength) | Out-Null
  }

  $bodyStart = $headerEnd + 4
  while (($data.Length - $bodyStart) -lt $contentLength) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) {
      break
    }
    $memory.Write($buffer, 0, $read)
    $data = $memory.ToArray()
  }

  $body = ""
  if ($contentLength -gt 0 -and $data.Length -ge ($bodyStart + $contentLength)) {
    $body = [System.Text.Encoding]::UTF8.GetString($data, $bodyStart, $contentLength)
  }

  $target = $requestParts[1]
  if ($target.StartsWith("http", [System.StringComparison]::OrdinalIgnoreCase)) {
    $uri = [uri]$target
  } else {
    $uri = [uri]"http://localhost:$Port$target"
  }

  $request = [pscustomobject]@{
    HttpMethod = $requestParts[0]
    Url = $uri
    HasEntityBody = $contentLength -gt 0
    ContentBody = $body
    Headers = $headers
    RemoteEndPoint = $Client.Client.RemoteEndPoint
  }

  return [pscustomobject]@{
    Client = $Client
    Stream = $stream
    Request = $request
  }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
$listener.Start()
$prefix = "http://localhost:$Port/"

Write-Host "Infra Monitor MVP rodando em $prefix"
Write-Host "Monitoramento: intervalo=${CheckIntervalSeconds}s, tentativas=$Attempts, timeout=${TimeoutMs}ms"
Write-Host "Pressione Ctrl+C para parar."

$nextCheck = (Get-Date).AddSeconds(2)

try {
  while ($true) {
    if ((Get-Date) -ge $nextCheck) {
      try {
        $checked = Invoke-MonitorCycle
        Write-Host ("Monitoramento executado: {0} dispositivo(s)." -f @($checked).Count)
      } catch {
        Write-Warning "Falha no ciclo de monitoramento: $($_.Exception.Message)"
      }
      $nextCheck = (Get-Date).AddSeconds($CheckIntervalSeconds)
    }

    $clientTask = $listener.AcceptTcpClientAsync()
    while (-not $clientTask.IsCompleted) {
      Start-Sleep -Milliseconds 150
      if ((Get-Date) -ge $nextCheck) {
        try {
          $checked = Invoke-MonitorCycle
          Write-Host ("Monitoramento executado: {0} dispositivo(s)." -f @($checked).Count)
        } catch {
          Write-Warning "Falha no ciclo de monitoramento: $($_.Exception.Message)"
        }
        $nextCheck = (Get-Date).AddSeconds($CheckIntervalSeconds)
      }
    }

    $client = $clientTask.Result
    try {
      $context = Read-TcpHttpContext $client
      if ($context.Request.Url.AbsolutePath.StartsWith("/api/")) {
        Handle-ApiRequest $context
      } else {
        Handle-StaticRequest $context
      }
    } catch {
      try {
        $fallbackContext = [pscustomobject]@{ Client = $client; Stream = $client.GetStream() }
        Send-Json $fallbackContext ([pscustomobject]@{ error = $_.Exception.Message }) 500
      } catch {
        $client.Close()
      }
    }
  }
} finally {
  $listener.Stop()
}
