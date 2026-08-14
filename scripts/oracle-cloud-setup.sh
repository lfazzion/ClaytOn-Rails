#!/usr/bin/env bash
# scripts/oracle-cloud-setup.sh
#
# Setup completo e otimizado para VM Oracle Cloud Always Free (Ampere A1 / Ubuntu 24.04 LTS)
# Execute como root ou com sudo após criar a instância.
#
# Uso:
#   curl -sSL https://raw.githubusercontent.com/seu-usuario/cleitin-bot/main/scripts/oracle-cloud-setup.sh | sudo bash
#
# Ou copie para a VM e execute:
#   sudo bash oracle-cloud-setup.sh
#
set -euo pipefail

log() { echo -e "\n\033[1;36m[setup] $*\033[0m"; }
ok()  { echo -e "\033[1;32m  ✔ $*\033[0m"; }
err() { echo -e "\033[1;31m  ✘ $*\033[0m" >&2; }

# ─── Validar ambiente ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Execute como root: sudo bash $0"
  exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
  log "AVISO: Arquitetura detectada: $ARCH (esperado: aarch64/ARM64)"
fi

log "=== Oracle Cloud VM Setup — Cleitin Bot ==="
log "Arquitetura: $ARCH"
log "RAM total: $(free -h | awk '/Mem:/{print $2}')"
log "CPUs: $(nproc)"

# ═══════════════════════════════════════════════════════════════════
# FASE 1: Sistema operacional
# ═══════════════════════════════════════════════════════════════════

log "FASE 1: Atualizando sistema operacional..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"
apt-get install -y -qq \
  curl wget git jq htop tmux unzip ca-certificates \
  gnupg lsb-release software-properties-common \
  apt-transport-https net-tools dnsutils \
  fail2ban iptables-persistent unattended-upgrades \
  build-essential chrony python3-systemd

# Limpeza de cache para economia de espaço em disco (50GB OCI)
apt-get clean
rm -rf /var/lib/apt/lists/*

ok "Sistema atualizado e pacotes instalados"

# ═══════════════════════════════════════════════════════════════════
# FASE 2: Segurança — SSH hardening
# ═══════════════════════════════════════════════════════════════════

log "FASE 2: Hardening SSH (Drop-in config)..."

# Criar diretório drop-in caso não exista
mkdir -p /etc/ssh/sshd_config.d

# Criar arquivo de configuração em vez de alterar o original (melhor prática 2026)
cat > /etc/ssh/sshd_config.d/99-cleitin-bot-hardening.conf <<'SSH_EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30

# Hardening 2026: Restrições Criptográficas (state-of-the-art, RFC 9142)
# ⚠ OCI Cloud Shell pode não suportar curve25519 — testar após aplicar.
#   Se bloqueado: adicionar ecdh-sha2-nistp256 ao KexAlgorithms.
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256@libssh.org,curve25519-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSH_EOF

# Criar diretório de privilege separation se não existir (fresh VM)
# Ref: systemd/systemd#31564 — Debian/Ubuntu usa /run/sshd (outros usam /usr/)
# Ref: monitorvps.com (Mar 2026) — bug idêntico no Ubuntu 24.04
mkdir -p /run/sshd
chmod 0755 /run/sshd

# Validar config antes de restart — erro de sintaxe = lockout SSH
if ! sshd -t; then
  err "SSH config inválida — revertendo drop-in"
  rm -f /etc/ssh/sshd_config.d/99-cleitin-bot-hardening.conf
  exit 1
fi

# Ubuntu 24.04: ssh.socket (socket activation) — drop-in é aplicado
# automaticamente na próxima conexão. Restart garante efeito imediato.
# Oracle Linux/RHEL: sshd.service — reload tradicional.
if systemctl is-active ssh.socket &>/dev/null; then
  systemctl restart ssh.socket
  ok "SSH hardening aplicado via drop-in (ssh.socket — efeito imediato)"
elif systemctl is-active ssh.service &>/dev/null; then
  systemctl reload ssh.service
  ok "SSH hardening aplicado via drop-in (ssh.service)"
else
  systemctl restart sshd.service
  ok "SSH hardening aplicado via drop-in (sshd.service — RHEL/OL)"
fi

# ═══════════════════════════════════════════════════════════════════
# FASE 3: Segurança — Firewall iptables (OCI Seguro)
# ═══════════════════════════════════════════════════════════════════

log "FASE 3: Configurando regras seguras iptables..."

# Em OCI não podemos zerar iptables, senão mata a máquina com lockout de boot volume.
# Inserimos as permissões no topo da cadeia INPUT de forma não-destrutiva.
# Idempotente: -C (check) falha se a regra não existe, então -I insere.
for PORT in 22 80 443; do
  case $PORT in
    22)  COMMENT="SSH" ;;
    80)  COMMENT="HTTP" ;;
    443) COMMENT="HTTPS" ;;
  esac
  iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT -m comment --comment "${COMMENT}" 2>/dev/null \
    || iptables -I INPUT 1 -p tcp --dport "${PORT}" -j ACCEPT -m comment --comment "${COMMENT}"
done

# Salvar as regras inseridas para sobrevivência após reboot
netfilter-persistent save >/dev/null 2>&1

ok "Firewall assegurado via iptables-persistent (Sem UFW)"

# ═══════════════════════════════════════════════════════════════════
# FASE 4: Segurança — Fail2Ban
# ═══════════════════════════════════════════════════════════════════

log "FASE 4: Configurando Fail2Ban..."

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd
allowipv6 = auto

[sshd]
enabled = true
port = ssh
# mode=aggressive = normal + ddos + extra (substitui o antigo jail sshd-ddos)
# Detecta: auth failures, conexões sem identificação, timeouts, protocolo inválido, negotiation failures
# Ref: github.com/fail2ban/fail2ban/blob/master/config/filter.d/sshd.conf
mode = aggressive
# journalmatch: Ubuntu 24.04 renomeou sshd.service → ssh.service.
# _COMM=sshd-session é para OpenSSH 9.8+ (outros distros, futuro Ubuntu).
# Cobertura cross-distro: + = AND entre pares, espaço = OR entre grupos.
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session
maxretry = 3
bantime = 86400
EOF

# Validar configuração antes de restart — erro de sintaxe = fail2ban não inicia
if ! fail2ban-client -t; then
  err "Configuração Fail2Ban inválida — abortando restart"
  exit 1
fi

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban configurado (SSH: 3 tentativas → ban 24h)"

# ═══════════════════════════════════════════════════════════════════
# FASE 5: Atualizações automáticas de segurança
# ═══════════════════════════════════════════════════════════════════

log "FASE 5: Atualizações automáticas de segurança..."

dpkg-reconfigure -plow unattended-upgrades -f noninteractive

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF

systemctl enable unattended-upgrades
ok "Atualizações automáticas de segurança habilitadas"

# ═══════════════════════════════════════════════════════════════════
# FASE 6: Swap via zRAM (Estado da arte OCI 2026)
# ═══════════════════════════════════════════════════════════════════

log "FASE 6: Configurando swap via zRAM..."

# Evitar swap em disco (poupa IOPS/escrita no boot volume da Oracle)
# Configuração manual via kernel module + systemd — funciona em qualquer distro,
# sem depender de zram-tools (Debian only) ou zram-config (formato diferente).
#
# Ref: FixPedia (Feb 2026) — systemd unit pattern para zram
# Ref: UbuntuHandbook (Aug 2024) — /sys/block/zram0 sysfs interface
# Ref: kernel docs — Documentation/admin-guide/blockdev/zram.rst

modprobe zram num_devices=1
echo "zstd" > /sys/block/zram0/comp_algorithm
echo "$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 2 ))K" > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0

# Service systemd para persistir após reboot
# Múltiplos ExecStart (um por passo) — padrão oneshot, mais legível que shell chain
cat > /etc/systemd/system/zram-setup.service <<'ZRAM_SVC'
[Unit]
Description=zRAM compressed swap
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStartPre=/sbin/modprobe zram num_devices=1
ExecStart=/bin/sh -c 'echo zstd > /sys/block/zram0/comp_algorithm'
ExecStart=/bin/sh -c 'echo $(( $(awk "/MemTotal/{print \$2}" /proc/meminfo) / 2 ))K > /sys/block/zram0/disksize'
ExecStart=/sbin/mkswap /dev/zram0
ExecStart=/sbin/swapon -p 100 /dev/zram0
ExecStop=/sbin/swapoff /dev/zram0
ExecStopPost=/bin/sh -c 'echo 1 > /sys/block/zram0/reset 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
ZRAM_SVC

systemctl daemon-reload
systemctl enable zram-setup
swapon --show
ok "zRAM swap configurado (zstd, 50% RAM) — service persistente"

# Remover arquivo de swap em disco legado, se existir
if swapon --show | grep -q '/swapfile'; then
  swapoff /swapfile || true
  rm -f /swapfile
  sed -i '\|/swapfile|d' /etc/fstab
  ok "Swapfile legado em disco removido"
fi

# Ajustar swappiness (mais agressivo para aproveitar compressão RAM)
# swappiness=100 é seguro com zRAM (swap comprimido em RAM, acesso quase zero),
# mas PERIGOSO com swap em disco físico — verificar sempre o contexto.
cat > /etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness=100
vm.vfs_cache_pressure=50
EOF
sysctl -p /etc/sysctl.d/99-swap.conf
ok "Swappiness ajustado para 100"

# ═══════════════════════════════════════════════════════════════════
# FASE 7: NTP — Chrony com OCI Managed NTP Service
# ═══════════════════════════════════════════════════════════════════
#
# OCI fornece NTP gerenciado via 169.254.169.254 (link-local metadata).
# Stratum 2, sincronizado contra Stratum 1 devices dedicados em cada AD.
# Ref: https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/configuringntpservice.htm
#
# Chrony é superior ao systemd-timesyncd em VMs:
# - Sincronização inicial mais rápida (segundos vs minutos)
# - Melhor performance com clock drift de VM (CPU scheduling)
# - Suporte a hardware timestamping
# - Acting como NTP server se necessário

log "FASE 7: Configurando NTP via Chrony (OCI)..."

# Desabilitar systemd-timesyncd — conflita com chrony
systemctl stop systemd-timesyncd 2>/dev/null || true
systemctl disable systemd-timesyncd 2>/dev/null || true

# Configurar chrony para OCI
cat > /etc/chrony/chrony.conf <<'CHRONY_EOF'
# ═══════════════════════════════════════════════════════════
# OCI Managed NTP Service — fonte primária
# 169.254.169.254 é o hypervisor metadata endpoint do OCI
# Stratum 2, baixa latência (< 1ms via VXLAN interno)
# ═══════════════════════════════════════════════════════════
server 169.254.169.254 iburst prefer

# Fallback: servidores públicos confiáveis caso OCI NTP fique indisponível
pool time.google.com iburst maxsources 2
pool time.cloudflare.com iburst maxsources 2

# Drift file — armazena offset de frequência para sync rápido após reboot
driftfile /var/lib/chrony/chrony.drift

# Para VMs: permitir step do clock sempre que offset > 1s
# VMs têm clock drift agressivo por CPU scheduling
makestep 1 -1

# RTC sync — mantém hardware clock preciso para boot correto
rtcsync

# Logs para diagnóstico
logdir /var/log/chrony
log tracking measurements statistics

# Leap second handling
leapsectz right/UTC

# Segurança: desabilitar command port (não gerenciado remotamente)
cmdport 0
CHRONY_EOF

# Garantir que o drift directory existe
mkdir -p /var/lib/chrony
chown _chrony:_chrony /var/lib/chrony 2>/dev/null || true

# Reiniciar e habilitar chrony
systemctl restart chrony
systemctl enable chrony
ok "Chrony configurado e habilitado (OCI NTP 169.254.169.254 + fallback público)"

# Aguardar sincronização inicial — waitsync é mais robusto que sleep fixo
# Ref: chronyc waitsync <max_loops> <max_error_seconds>
# - max_loops: número máximo de tentativas (1s entre cada)
# - max_error: offset máximo aceitável em segundos
if chronyc waitsync 30 0.1 2>/dev/null; then
  ok "NTP sincronizado (offset < 100ms)"
else
  log "AVISO: Sincronização inicial não atingiu 100ms em 30s — continuando"
  log "  Chrony continuará sincronizando em background"
  log "  Verificar com: chronyc tracking"
fi

# Mostrar status para o operador
chronyc sources -n 2>/dev/null || true
chronyc tracking 2>/dev/null | grep -E "Reference ID|Stratum|System time|Leap status" || true

# ═══════════════════════════════════════════════════════════════════
# FASE 8: Docker + Docker Compose
# ═══════════════════════════════════════════════════════════════════

log "FASE 8: Instalando Docker..."

# Remover versões antigas (se houver)
apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

# Adicionar repositório oficial Docker
mkdir -p /etc/apt/keyrings
DOCKER_GPG_TMP=$(mktemp)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_GPG_TMP"
DOCKER_FP=$(gpg --with-colons --import-options show-only --import "$DOCKER_GPG_TMP" 2>/dev/null \
  | awk -F: '/^fpr:/{print $10; exit}')
EXPECTED_DOCKER_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
if [[ "$DOCKER_FP" != "$EXPECTED_DOCKER_FP" ]]; then
  rm -f "$DOCKER_GPG_TMP"
  err "Docker GPG key fingerprint mismatch!"
  err "Got:      ${DOCKER_FP:-<empty>}"
  err "Expected: ${EXPECTED_DOCKER_FP}"
  exit 1
fi
gpg --dearmor -o /etc/apt/keyrings/docker.gpg < "$DOCKER_GPG_TMP"
rm -f "$DOCKER_GPG_TMP"
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
ok "Docker instalado"

# Configurar daemon Docker
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "mtu": 1400,
  "storage-driver": "overlay2",
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  },
  "metrics-addr": "127.0.0.1:9323",
  "experimental": false
}
EOF

systemctl restart docker
systemctl enable docker
ok "Docker daemon configurado (live-restore, logs limitados, metrics)"

# Adicionar usuário ao grupo docker
DOCKER_USER="${SUDO_USER:-$(logname 2>/dev/null || echo ubuntu)}"
if id "${DOCKER_USER}" &>/dev/null; then
  usermod -aG docker "${DOCKER_USER}"
  ok "Usuário ${DOCKER_USER} adicionado ao grupo docker"
else
  err "Usuário ${DOCKER_USER} não existe — adicione manualmente: usermod -aG docker <usuario>"
fi

# Plataforma Docker padrão ARM64 (evita QEMU x86→ARM em builds)
# /etc/profile.d/ funciona para login shells (SSH, su -) — mais robusto que ~/.profile
cat > /etc/profile.d/docker-platform.sh <<'EOF'
export DOCKER_DEFAULT_PLATFORM=linux/arm64
EOF
chmod 644 /etc/profile.d/docker-platform.sh
ok "DOCKER_DEFAULT_PLATFORM=linux/arm64 adicionado ao /etc/profile.d/"

# ═══════════════════════════════════════════════════════════════════
# FASE 9: Otimizações de kernel
# ═══════════════════════════════════════════════════════════════════

log "FASE 9: Otimizações de kernel..."

cat > /etc/sysctl.d/99-cleitin-bot.conf <<'EOF'
# Network performance
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# File descriptors
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288

# Memory — heurístico padrão, evita OOM kills agressivos
vm.overcommit_memory = 0
vm.panic_on_oom = 0
EOF

# Carregar módulo BBR antes do sysctl — não é builtin, é módulo carregável
if modprobe tcp_bbr 2>/dev/null; then
  ok "Módulo tcp_bbr carregado"
else
  log "AVISO: Módulo tcp_bbr não disponível — BBR pode não funcionar"
fi

# Garantir carregamento automático no boot
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

sysctl -p /etc/sysctl.d/99-cleitin-bot.conf
ok "Kernel tunado (network, file descriptors, OOM)"

# Aumentar limites de arquivo para o usuário detectado
cat > /etc/security/limits.d/99-cleitin-bot.conf <<EOF
${DOCKER_USER} soft nofile 65536
${DOCKER_USER} hard nofile 65536
${DOCKER_USER} soft nproc 16384
${DOCKER_USER} hard nproc 16384
EOF
ok "Limites de arquivo aumentados para ${DOCKER_USER} (65536)"

# ═══════════════════════════════════════════════════════════════════
# FASE 10: Deploy do Cleitin Bot
# ═══════════════════════════════════════════════════════════════════

log "FASE 10: Preparando diretório do projeto..."

PROJECT_DIR="/opt/cleitin-bot"
mkdir -p "$PROJECT_DIR"
chown "${DOCKER_USER}:${DOCKER_USER}" "$PROJECT_DIR"
ok "Diretório $PROJECT_DIR criado"

# Criar diretório storage com permissões abertas para o bind mount Docker.
# O container roda como usuário 'rails' (UID interno), mas o bind mount
# pertence ao 'ubuntu' (UID 1000). SQLite precisa criar arquivos aqui.
STORAGE_DIR="$PROJECT_DIR/storage"
mkdir -p "$STORAGE_DIR"
chmod 777 "$STORAGE_DIR"
ok "Storage directory criado com permissões para bind mount Docker"

# ═══════════════════════════════════════════════════════════════════
# FASE 10.5: Timer semanal de limpeza de imagens Docker
# ═══════════════════════════════════════════════════════════════════

log "FASE 10.5: Configurando limpeza semanal de imagens Docker..."

cat > /etc/systemd/system/docker-image-prune.service <<'PRUNE_SVC_EOF'
[Unit]
Description=Docker image prune (remove unused images older than 7 days)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -a -f --filter "until=168h"
ExecStartPost=/usr/bin/docker builder prune -f --filter "until=168h"
PRUNE_SVC_EOF

cat > /etc/systemd/system/docker-image-prune.timer <<'PRUNE_TMR_EOF'
[Unit]
Description=Weekly Docker image cleanup

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
PRUNE_TMR_EOF

systemctl daemon-reload
systemctl enable --now docker-image-prune.timer
ok "Timer semanal de limpeza de imagens Docker habilitado (domingos 03:00)"

cat <<DEPLOY_MSG

═══════════════════════════════════════════════════════════════
  PRÓXIMOS PASSOS — Como deployar o Cleitin Bot:
═══════════════════════════════════════════════════════════════

  1. Clonar o repositório:

     sudo -u ${DOCKER_USER} git clone <SEU_REPO_URL> /opt/cleitin-bot

  2. Configurar variáveis de ambiente:

     sudo -u ${DOCKER_USER} cp /opt/cleitin-bot/.env.example /opt/cleitin-bot/.env
     sudo -u ${DOCKER_USER} nano /opt/cleitin-bot/.env

  3. Subir os containers:

     cd /opt/cleitin-bot
     docker compose -f docker/docker-compose.yml up -d

  4. Verificar status:

     docker compose -f docker/docker-compose.yml ps
     docker compose -f docker/docker-compose.yml logs -f --tail=50

═══════════════════════════════════════════════════════════════
  SEGURANÇA APLICADA:
═══════════════════════════════════════════════════════════════

  ✔ SSH: root desabilitado, drop-in conf, LoginGraceTime 30 (Slowloris protection)
  ✔ Firewall Seguro: OCI Security Lists combinadas com iptables, sem UFW
  ✔ Fail2Ban: mode=aggressive (auth + ddos + extra), journalmatch systemd
  ✔ SSH KEX: sntrup761x25519 (post-quantum) + curve25519 (fallback)
  ✔ Atualizações automáticas de segurança
  ✔ Swap zRAM 50% RAM com swappiness=100
  ✔ NTP: Chrony via OCI Managed NTP (169.254.169.254) + fallback público
  ✔ Docker: local log driver (binary compressed)
  ✔ Docker platform: linux/arm64 (sem QEMU)
  ✔ Kernel: TCP BBR + FQ-CoDel

═══════════════════════════════════════════════════════════════
  HARDENING OPCIONAL (não aplicado automaticamente):
═══════════════════════════════════════════════════════════════

  ⚠ Docker userns-remap: protege contra container→host escape,
    mas QUEBRA bind mounts (storage/). Para aplicar:

    1. Pare todos os containers
    2. Adicione "userns-remap": "default" ao daemon.json
    3. REFAÇA o chown: chown -R 100000:100000 /opt/cleitin-bot/storage
    4. Reinicie Docker: systemctl restart docker
    5. Reconstrua: docker compose -f docker/docker-compose.yml build --no-cache

═══════════════════════════════════════════════════════════════

═══════════════════════════════════════════════════════════════

DEPLOY_MSG

log "=== Setup concluído com sucesso ==="
