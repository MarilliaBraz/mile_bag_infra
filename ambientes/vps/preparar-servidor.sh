#!/bin/bash
# Preparação da VPS (Ubuntu 24.04), rodada como root NO SERVIDOR por scripts/vps.sh preparar. Pode rodar de novo:
# o que já está feito é pulado.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

virt="$(systemd-detect-virt || true)"
echo "Virtualização: $virt"
case "$virt" in
  openvz | lxc | lxc-libvirt)
    echo "Esta VPS é um contêiner ($virt): o Docker pode não funcionar. Fale com o provedor antes de seguir." >&2
    exit 1
    ;;
esac

echo "Atualizando o sistema ..."
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl ufw rsync unattended-upgrades fail2ban
timedatectl set-timezone America/Sao_Paulo

if ! command -v docker >/dev/null; then
  echo "Instalando o Docker (script oficial get.docker.com) ..."
  curl -fsSL https://get.docker.com | sh
fi
# Logs dos contêineres com rotação (o driver "local" limita o tamanho sozinho), para não encher o disco.
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{ "log-driver": "local" }' >/etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker >/dev/null

# 2 GB de swap: folga para o Java da API e o Valhalla numa máquina de 4 GB.
if ! swapon --show | grep -q .; then
  echo "Criando 2 GB de swap ..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# Firewall: só SSH, HTTP e HTTPS. (O banco não publica porta nenhuma, então nem passa por aqui.)
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null

mkdir -p /opt/milebag/backups
chmod 700 /opt/milebag/backups
chmod 700 /opt/milebag
echo '30 3 * * * root /opt/milebag/backup.sh >>/var/log/milebag-backup.log 2>&1' >/etc/cron.d/milebag-backup

docker --version
docker compose version
echo "Servidor pronto."
