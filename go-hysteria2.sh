#!/bin/bash
set -euo pipefail

if [[ $(id -u) != 0 ]]; then
    echo Please run this script as root.
    exit 1
fi

if [[ $(uname -m 2> /dev/null) != x86_64 ]]; then
    echo Please run this script on x86_64 machine.
    exit 1
fi

CERTPATH=$1
PASSKEY=$2

if [[ -z $CERTPATH ]]; then
    echo Please pass a path that store the SSL certificate.
    exit 1
fi

if ! [[ -d $CERTPATH ]]; then
    echo Please enter a valid path for SSL certificate.
    exit 1
fi

if [[ -z $PASSKEY ]]; then
    echo Please pass a password.
    exit 1
fi

NAME=hysteria
VERSION=$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | sed -E 's/.*"app\/v(.*)".*/\1/')
TARBALL="$NAME-linux-amd64"
DOWNLOADURL="https://github.com/apernet/hysteria/releases/download/app/v$VERSION/$TARBALL"
TMPDIR="$(mktemp -d)"
INSTALLPREFIX=/usr/local
SYSTEMDPREFIX=/usr/lib/systemd/system

BINARYPATH="$INSTALLPREFIX/bin/$NAME"
CONFIGPATH="$INSTALLPREFIX/etc/$NAME/config.yaml"
SYSTEMDPATH="$SYSTEMDPREFIX/$NAME.service"

echo Entering temp directory $TMPDIR...
cd "$TMPDIR"

echo Downloading $NAME $VERSION...
curl -LO --progress-bar "$DOWNLOADURL" || wget -q --show-progress "$DOWNLOADURL"

echo Installing $NAME $VERSION to $BINARYPATH...
install -Dm755 "$NAME" "$BINARYPATH"

EXAMPLEPATH="server.yaml"
echo Installing $NAME server config to $CONFIGPATH...
if ! [[ -f "$CONFIGPATH" ]]; then
    cat > "$EXAMPLEPATH" << EOF
listen: "[::]:443"

tls:
  cert: $CERTPATH/certificatev6.crt
  key: $CERTPATH/privatev6.key

auth:
  type: password
  password: $PASSKEY

masquerade:
  type: proxy
  proxy:
    url: https://ultracold273.github.io
    rewrite-host: true
EOF
    install -Dm644 "$EXAMPLEPATH" "$CONFIGPATH"
else
    echo Skipping installing $NAME server config...
fi

if [[ -d "$SYSTEMDPREFIX" ]]; then
    echo Installing $NAME systemd service to $SYSTEMDPATH...
    if ! [[ -f "$SYSTEMDPATH" ]]; then
        cat > "$SYSTEMDPATH" << EOF
[Unit]
Description=$NAME
Documentation=https://github.com/apernet/hysteria https://v2.hysteria.network
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
StandardError=journal
ExecStart="$BINARYPATH" server --config "$CONFIGPATH"
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=51200
Restart=on-failure
RestartSec=1s
User=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

        echo Reloading systemd daemon...
        systemctl daemon-reload
    else
        echo Skipping installing $NAME systemd service...
    fi
fi

echo Deleting temp directory $TMPDIR...
rm -rf "$TMPDIR"

echo Done!