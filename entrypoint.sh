#!/usr/bin/env bash

set -v

# fail entire script if anything fails, including a pipe
set -eo pipefail

banner_echo() {
  printf "\n\033[0;36m%s   \033[0m\n" "$1"
}

if ! command -v localias >/dev/null & then
  # TODO use hosted version https://github.com/peterldowns/localias/pull/44
  banner_echo "Installing localias"
  cat "$GITHUB_ACTION_PATH/install.sh" | bash -s -- --yes
fi

# to view logs, run detached `sudo localaias run &`
banner_echo "Starting localias..."
sudo localias start

# wait until the daemon has finished initializing
# file is normally located at: /root/.local/state/localias/caddy/pki/authorities/local/root.crt

cert_location=$(sudo localias debug cert)

# this can occur if there was an error installing localias
if [ -z "$cert_location" ]; then
  banner_echo "ERROR: Failed to get certificate location from localias debug cert command"
  exit 1
fi

daemon_success=false

for i in {1..5}; do
  banner_echo "Checking for self-signed cert: $cert_location..."

  # NOTE sudo is really important here, without this the check will fail since the file is protected
  if sudo [ -f "$cert_location" ]; then
    daemon_success=true
  else
    sleep 2
  fi

  if $daemon_success; then
    break
  fi
done

$daemon_success || exit 1

banner_echo "Creating shared NSS DB..."
# when this directory is properly configured, you should see the following files: cert9.db  key4.db  pkcs11.txt
[ ! -d "$HOME/.pki/nssdb" ] && mkdir -p "$HOME/.pki/nssdb" && certutil -d sql:$HOME/.pki/nssdb -N --empty-password

# https://chromium.googlesource.com/chromium/src/+/master/docs/linux/cert_management.md
banner_echo "Installing certificates for Chrome and others using shared NSS DB..."
sudo certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n localias-cert -i $(sudo localias debug cert)

banner_echo "Installed certificates:"
certutil -L -d sql:${HOME}/.pki/nssdb

# localias (caddy) appends the self-signed certificate to /etc/ssl/certs/ca-certificates.crt
# but the system is not refreshed, which causes curl and various other systems to *not* pick up on the new certificate
banner_echo "Refreshing system CA certs..."
sudo update-ca-certificates --fresh

# reset DNS, could cause issues with custom domains
sudo systemctl restart systemd-resolved

# certs are *not* installed by Caddy in the right location by default
# specifically, we know this fixes `curl` so it respects our self-signed SSL certificates
# banner_echo "Installing locally signed cert"
# sudo localias debug cert --print | sudo tee -a /etc/ssl/certs/ca-certificates.crt

# https://stackoverflow.com/a/75352343/129415
# TODO should we set this here? makes httpie work?
# REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
# export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# export NODE_EXTRA_CA_CERTS="/path/to/cert.pem"

# TODO leave this here in case we are able to identify a link between time drifts and cert issues
banner_echo "Datetime config..."
timedatectl

# each individual test domain should be tested/warmed up, otherwise downstream services may get an SSL error
test_domains=$(localias debug config --print | grep -v '^#' | grep -v '^$' | cut -d: -f1 | tr -d ' ')

for test_domain in $test_domains; do
  banner_echo "Testing $test_domain..."
  curl_success=false
  for i in {1..5}; do
    banner_echo "Checking HTTPs via curl..."
    curl -vvv --head "$test_domain" && curl_success=true && break || sleep 2
  done
  $curl_success || exit 1
done

if [ $WARM_CHROME = "true" ]; then
  # abs path to py binaries in case mise or other version managers have a custom version of py installed
  # we don't want to clobber than environment
  /usr/bin/pip install playwright
  playwright install chromium --only-shell
  for test_domain in $test_domains; do
    banner_echo "Testing Chrome $test_domain..."
    /usr/bin/python "$GITHUB_ACTION_PATH/warm_chrome.py" "$test_domain"
  done
  /usr/bin/pip uninstall --yes playwright
fi

banner_echo "Tailing localias logs..."
sudo tail -n 0 -f /root/.local/state/localias/daemon.log &
